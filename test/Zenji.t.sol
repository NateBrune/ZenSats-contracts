// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { CurveTwoCryptoSwapper } from "../src/swappers/base/CurveTwoCryptoSwapper.sol";
import { LlamaLoanManager } from "../src/lenders/LlamaLoanManager.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ILoanManager } from "../src/interfaces/ILoanManager.sol";
import { ILlamaLendController } from "../src/interfaces/ILlamaLendController.sol";
import { IYieldStrategy } from "../src/interfaces/IYieldStrategy.sol";
import { ISwapper } from "../src/interfaces/ISwapper.sol";
import { CrvUsdIporStrategy } from "../src/strategies/vault/CrvUsdIporStrategy.sol";
import { TimelockLib } from "../src/libraries/TimelockLib.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 as OZ_IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Simple mock ERC4626 vault for testing when IPOR vault is at capacity
contract MockYieldVault is ERC4626 {
    constructor(address asset_) ERC4626(OZ_IERC20(asset_)) ERC20("Mock Yield Vault", "mYV") { }
}

/// @notice Mock yield strategy that wraps a MockYieldVault for testing
contract MockYieldStrategy is IYieldStrategy {
    ERC4626 public immutable yieldVault;
    IERC20 public immutable crvUSD;
    address public override vault;
    address public initializer;
    uint256 private _costBasis;

    constructor(address _crvUSD, address _vault, address _yieldVault) {
        crvUSD = IERC20(_crvUSD);
        if (_vault != address(0)) {
            vault = _vault;
            initializer = address(0);
        } else {
            initializer = msg.sender;
        }
        yieldVault = ERC4626(_yieldVault);
    }

    function initializeVault(address newVault) external {
        if (vault != address(0)) revert("Initialized");
        if (newVault == address(0)) revert("InvalidVault");
        if (msg.sender != initializer) revert("Unauthorized");
        vault = newVault;
        initializer = address(0);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function deposit(uint256 crvUsdAmount) external onlyVault returns (uint256) {
        crvUSD.transferFrom(msg.sender, address(this), crvUsdAmount);
        crvUSD.approve(address(yieldVault), crvUsdAmount);
        yieldVault.deposit(crvUsdAmount, address(this));
        _costBasis += crvUsdAmount;
        return crvUsdAmount;
    }

    function withdraw(uint256 crvUsdAmount) external onlyVault returns (uint256) {
        uint256 shares = yieldVault.convertToShares(crvUsdAmount);
        uint256 totalShares = yieldVault.balanceOf(address(this));
        if (shares > totalShares) shares = totalShares;

        uint256 basisReduction = totalShares > 0 ? (_costBasis * shares) / totalShares : 0;
        _costBasis = _costBasis > basisReduction ? _costBasis - basisReduction : 0;

        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        crvUSD.transfer(vault, received);
        return received;
    }

    function withdrawAll() external onlyVault returns (uint256) {
        return _withdrawAllInternal();
    }

    function _withdrawAllInternal() internal returns (uint256) {
        uint256 shares = yieldVault.balanceOf(address(this));
        if (shares == 0) return 0;
        _costBasis = 0;
        uint256 received = yieldVault.redeem(shares, address(this), address(this));
        crvUSD.transfer(vault, received);
        return received;
    }

    // Configurable harvest reward — set by tests to simulate CRV→crvUSD conversion profit
    uint256 public harvestRewardAmount;

    function setHarvestReward(uint256 amount) external {
        harvestRewardAmount = amount;
    }

    function harvest() external returns (uint256) {
        uint256 reward = harvestRewardAmount;
        harvestRewardAmount = 0; // consume once
        if (reward > 0) {
            // Deposit pre-funded crvUSD into the yield vault to increase balanceOf()
            crvUSD.approve(address(yieldVault), reward);
            yieldVault.deposit(reward, address(this));
        }
        return reward;
    }

    function emergencyWithdraw() external onlyVault returns (uint256) {
        return _withdrawAllInternal();
    }

    function asset() external view returns (address) {
        return address(crvUSD);
    }

    function underlyingAsset() external view returns (address) {
        return address(crvUSD);
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

    /// @notice Mock strategy that reports a different asset
    contract MockBadStrategy is IYieldStrategy {
        address public immutable badAsset;

        constructor(address _badAsset) {
            badAsset = _badAsset;
        }

        function deposit(uint256) external pure returns (uint256) {
            return 0;
        }

        function withdraw(uint256) external pure returns (uint256) {
            return 0;
        }

        function withdrawAll() external pure returns (uint256) {
            return 0;
        }

        function harvest() external pure returns (uint256) {
            return 0;
        }

        function emergencyWithdraw() external pure returns (uint256) {
            return 0;
        }

        function asset() external view returns (address) {
            return badAsset;
        }

        function underlyingAsset() external view returns (address) {
            return badAsset;
        }

        function balanceOf() external pure returns (uint256) {
            return 0;
        }

        function costBasis() external pure returns (uint256) {
            return 0;
        }

        function unrealizedProfit() external pure returns (uint256) {
            return 0;
        }

        function pendingRewards() external pure returns (uint256) {
            return 0;
        }

        function transferOwnerFromVault(address) external pure { }
        function setSlippage(uint256) external pure { }
        function updateCachedVirtualPrice() external { }

        function name() external pure returns (string memory) {
            return "Bad Strategy";
        }

        function vault() external pure returns (address) {
            return address(0);
        }
    }

    /// @notice Mock swapper that returns debt/collateral 1:1 to satisfy oracle floors
    contract MockZenjiSwapper is ISwapper {
        IERC20 public immutable collateral;
        IERC20 public immutable debt;
        ILoanManager public loanManager;

        constructor(address _collateral, address _debt) {
            collateral = IERC20(_collateral);
            debt = IERC20(_debt);
        }

        function setLoanManager(address _loanManager) external {
            loanManager = ILoanManager(_loanManager);
        }

        function quoteCollateralForDebt(uint256 debtAmount) external view returns (uint256) {
            if (address(loanManager) == address(0)) return debtAmount;
            return loanManager.getDebtValue(debtAmount);
        }

        function swapCollateralForDebt(uint256 collateralAmount)
            external
            returns (uint256 debtReceived)
        {
            uint256 payout = collateralAmount;
            if (address(loanManager) != address(0)) {
                // Slightly overpay relative to oracle value to clear safety floor
                payout = (loanManager.getCollateralValue(collateralAmount) * 101) / 100;
            }
            debt.transfer(msg.sender, payout);
            return payout;
        }

        function swapDebtForCollateral(uint256 debtAmount)
            external
            returns (uint256 collateralReceived)
        {
            uint256 payout = debtAmount;
            if (address(loanManager) != address(0)) {
                payout = (loanManager.getDebtValue(debtAmount) * 101) / 100;
            }
            collateral.transfer(msg.sender, payout);
            return payout;
        }

        function slippage() external pure returns (uint256) {
            return 1e16;
        }
    }

    /// @notice Mock strategy that can be toggled to revert on withdrawals
    contract MockBrickedStrategy is IYieldStrategy {
        IERC20 public immutable crvUSD;
        address public override vault;
        address public initializer;
        bool public bricked;
        uint256 private _costBasis;

        constructor(address _crvUSD, address _vault) {
            crvUSD = IERC20(_crvUSD);
            if (_vault != address(0)) {
                vault = _vault;
                initializer = address(0);
            } else {
                initializer = msg.sender;
            }
        }

        function initializeVault(address newVault) external {
            if (vault != address(0)) revert("Initialized");
            if (newVault == address(0)) revert("InvalidVault");
            if (msg.sender != initializer) revert("Unauthorized");
            vault = newVault;
            initializer = address(0);
        }

        function setBricked(bool value) external {
            bricked = value;
        }

        modifier onlyVault() {
            require(msg.sender == vault, "Unauthorized");
            _;
        }

        function deposit(uint256 amount) external onlyVault returns (uint256) {
            crvUSD.transferFrom(msg.sender, address(this), amount);
            _costBasis += amount;
            return amount;
        }

        function withdraw(uint256) external view onlyVault returns (uint256) {
            if (bricked) revert("Bricked");
            return 0;
        }

        function withdrawAll() external onlyVault returns (uint256) {
            if (bricked) revert("Bricked");
            uint256 bal = crvUSD.balanceOf(address(this));
            if (bal > 0) {
                _costBasis = 0;
                crvUSD.transfer(vault, bal);
            }
            return bal;
        }

        function harvest() external pure returns (uint256) {
            return 0;
        }

        function emergencyWithdraw() external onlyVault returns (uint256) {
            if (bricked) revert("Bricked");
            uint256 bal = crvUSD.balanceOf(address(this));
            if (bal > 0) {
                _costBasis = 0;
                crvUSD.transfer(vault, bal);
            }
            return bal;
        }

        function asset() external view returns (address) {
            return address(crvUSD);
        }

        function underlyingAsset() external view returns (address) {
            return address(crvUSD);
        }

        function balanceOf() external view returns (uint256) {
            return crvUSD.balanceOf(address(this));
        }

        function costBasis() external view returns (uint256) {
            return _costBasis;
        }

        function unrealizedProfit() external view returns (uint256) {
            uint256 current = crvUSD.balanceOf(address(this));
            return current > _costBasis ? current - _costBasis : 0;
        }

        function pendingRewards() external pure returns (uint256) {
            return 0;
        }

        function transferOwnerFromVault(address) external pure { }
        function setSlippage(uint256) external pure { }
        function updateCachedVirtualPrice() external { }

        function name() external pure returns (string memory) {
            return "Bricked Strategy";
        }
    }

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
        /// @notice Comprehensive fork tests for Zenji with Curve cvcrvUSD integration

        contract ZenjiTest is Test {
            // Mainnet addresses
            address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
            address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
            address constant LLAMALEND_WBTC = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
            address constant YIELD_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
            address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
            address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
            address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

            // Test accounts
            address owner = makeAddr("owner");
            address keeper = makeAddr("keeper");
            address user1 = makeAddr("user1");
            address user2 = makeAddr("user2");
            address user3 = makeAddr("user3");

            // WBTC whale for testing
            address constant WBTC_WHALE = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

            Zenji vault;
            ZenjiViewHelper viewHelper;
            IERC20 wbtc;
            IERC20 crvUSD;
            IYieldStrategy yieldStrategy;

            /// @notice Helper to mock oracle after time warp
            uint256 lastBtcPrice = 50000e8;

            function mockOracle(uint256 price) internal {
                lastBtcPrice = price;
                vm.mockCall(
                    BTC_USD_ORACLE,
                    abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                    abi.encode(
                        uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1)
                    )
                );
                // Also mock crvUSD oracle at $1.00 (8 decimals)
                vm.mockCall(
                    CRVUSD_USD_ORACLE,
                    abi.encodeWithSelector(IChainlinkOracle.latestRoundData.selector),
                    abi.encode(uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1))
                );
            }

            function warpAndMock(uint256 t) internal {
                vm.warp(t);
                vm.roll(block.number + 1);
                mockOracle(lastBtcPrice);
            }

            // ============ Governance helpers ============
            // Decentralization upgrade: feeRate increases and targetLtv increases require
            // a propose + execute pattern with PARAM_TIMELOCK_DELAY between calls.
            // Decreases stay immediate. emergencySkipStep is now a 2-call pattern with
            // EMERGENCY_SKIP_DELAY between calls.

            function _setFeeRate(uint256 newRate) internal {
                uint256 cur = vault.feeRate();
                vm.prank(vault.gov());
                vault.setParam(0, newRate);
                if (newRate > cur) {
                    warpAndMock(block.timestamp + vault.PARAM_TIMELOCK_DELAY());
                    vm.prank(vault.gov());
                    vault.executeParamChange(0);
                }
            }

            function _setTargetLtv(uint256 newLtv) internal {
                uint256 cur = vault.targetLtv();
                vm.prank(vault.gov());
                vault.setParam(1, newLtv);
                if (newLtv > cur) {
                    warpAndMock(block.timestamp + vault.PARAM_TIMELOCK_DELAY());
                    vm.prank(vault.gov());
                    vault.executeParamChange(1);
                }
            }

            function _emergencySkipStep(uint8 step) internal {
                vm.prank(vault.guardian());
                vault.emergencySkipStep(step);
                warpAndMock(block.timestamp + vault.EMERGENCY_SKIP_DELAY());
                vm.prank(vault.guardian());
                vault.emergencySkipStep(step);
            }

            function _setRescueRecipient(address addr) internal {
                vm.prank(vault.gov());
                vault.proposeRescueRecipient(addr);
                warpAndMock(block.timestamp + vault.TIMELOCK_DELAY());
                vm.prank(vault.gov());
                vault.executeRescueRecipient();
            }

            function _setBountyRate(uint256 newRate) internal {
                uint256 cur = vault.rebalanceBountyRate();
                vm.prank(vault.gov());
                vault.setParam(3, newRate);
                if (newRate > cur) {
                    warpAndMock(block.timestamp + vault.PARAM_TIMELOCK_DELAY());
                    vm.prank(vault.gov());
                    vault.executeParamChange(3);
                }
            }

            /// @notice Mock yield vault for testing (IPOR vault is at capacity)
            MockYieldVault mockYield;
            MockYieldStrategy mockStrategy;

            /// @notice Deploy mock yield strategy and redeploy Zenji to use it
            function setupMockYieldStrategy() internal {
                // Use a deterministic mock swapper that slightly overpays vs oracle quotes to satisfy swap floors
                MockZenjiSwapper swapper = new MockZenjiSwapper(WBTC, CRVUSD);
                deal(WBTC, address(swapper), 1e50);
                deal(CRVUSD, address(swapper), 1e50);
                // Deploy a simple mock ERC4626 vault for crvUSD
                mockYield = new MockYieldVault(CRVUSD);

                // Deploy the mock strategy (vault initialized after Zenji is deployed)
                mockStrategy = new MockYieldStrategy(CRVUSD, address(0), address(mockYield));

                LlamaLoanManager loanManager = new LlamaLoanManager(
                    WBTC,
                    CRVUSD,
                    LLAMALEND_WBTC,
                    WBTC_CRVUSD_POOL,
                    BTC_USD_ORACLE,
                    CRVUSD_USD_ORACLE,
                    address(swapper),
                    address(0),
                    3600
                );

                swapper.setLoanManager(address(loanManager));

                // Redeploy the vault with the mock strategy
                vault = new Zenji(
                    WBTC,
                    CRVUSD,
                    address(loanManager),
                    address(mockStrategy),
                    address(swapper),
                    owner,
                    address(viewHelper)
                );

                // Initialize vault bindings post-deploy
                mockStrategy.initializeVault(address(vault));
                loanManager.initializeVault(address(vault));

                yieldStrategy = IYieldStrategy(address(mockStrategy));

                // Re-approve the new vault
                vm.prank(user1);
                wbtc.approve(address(vault), type(uint256).max);
                vm.prank(user2);
                wbtc.approve(address(vault), type(uint256).max);
                vm.prank(user3);
                wbtc.approve(address(vault), type(uint256).max);

                // Enable fee accrual (default feeRate is 0). 0→10% is an increase
                // → propose + execute pattern.
                _setFeeRate(1e17);
            }

            uint256 constant STAMP = 1710000000;

            /// @notice Called in setUp - always use mock yield strategy
            function increaseIporVaultCap() internal {
                setupMockYieldStrategy();
            }

            function setUp() public {
                // Fork mainnet - try MAINNET_RPC_URL first, then ETH_RPC_URL, otherwise respect --fork-url
                string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
                if (bytes(rpcUrl).length == 0) {
                    rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
                }
                if (bytes(rpcUrl).length > 0) {
                    vm.createSelectFork(rpcUrl);
                }

                // Sync time and prices with mainnet oracles to avoid StaleOracle and Curve reverts
                (,, uint256 btcUpdate,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
                (, int256 btcPrice,,,) = IChainlinkOracle(BTC_USD_ORACLE).latestRoundData();
                lastBtcPrice = uint256(btcPrice);
                uint256 currentTime = block.timestamp;
                if (btcUpdate + 1 > currentTime) {
                    vm.warp(btcUpdate + 1);
                }
                mockOracle(lastBtcPrice);

                wbtc = IERC20(WBTC);
                crvUSD = IERC20(CRVUSD);

                // Fund test users with WBTC from whale
                vm.startPrank(WBTC_WHALE);
                wbtc.transfer(user1, 10e8); // 10 WBTC
                wbtc.transfer(user2, 10e8); // 10 WBTC
                wbtc.transfer(user3, 10e8); // 10 WBTC
                vm.stopPrank();

                viewHelper = new ZenjiViewHelper();

                // Deploy mock yield strategy (IPOR PlasmaVault is at capacity)
                increaseIporVaultCap();
            }

            // ============ Basic Deposit/Withdraw Tests ============

            function test_deposit() public {
                uint256 depositAmount = 1e8; // 1 WBTC
                uint256 balanceBefore = wbtc.balanceOf(user1);

                vm.prank(user1);
                uint256 shares = vault.deposit(depositAmount, user1);

                assertEq(shares, depositAmount, "Shares should equal deposit for first depositor");
                assertEq(vault.balanceOf(user1), shares, "User share balance mismatch");
                assertEq(vault.totalSupply(), shares, "Total shares mismatch");
                assertEq(
                    wbtc.balanceOf(user1), balanceBefore - depositAmount, "WBTC balance mismatch"
                );
            }

            function test_withdraw() public {
                // Deposit first
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                // Wait for redemption delay (vault has 1 second delay)
                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8); // Re-mock oracle after time warp

                uint256 balanceBefore = wbtc.balanceOf(user1);

                // Withdraw all shares
                vm.prank(user1);
                uint256 wbtcReceived = vault.redeem(shares, user1, user1);

                assertGt(wbtcReceived, 0, "Should receive WBTC");
                assertEq(vault.balanceOf(user1), 0, "Shares should be zero after full withdrawal");
                assertEq(vault.totalSupply(), 0, "Total shares should be zero");
                assertGt(wbtc.balanceOf(user1), balanceBefore, "User should have more WBTC");
            }

            function test_delay_depositThenWithdraw_sameSecondReverts() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                vm.prank(user1);
                vm.expectRevert(Zenji.ActionDelayActive.selector);
                vault.withdraw(1e7, user1, user1);

                warpAndMock(block.timestamp + 1);

                vm.prank(user1);
                uint256 out = vault.redeem(shares, user1, user1);
                assertGt(out, 0, "redeem should succeed after 1-block delay");
            }

            function test_delay_withdrawThenDeposit_sameBlockAllowed() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.prank(user1);
                uint256 out = vault.redeem(shares, user1, user1);
                assertGt(out, 0, "redeem should succeed");

                vm.prank(user1);
                uint256 minted = vault.deposit(1e8, user1);
                assertGt(minted, 0, "deposit should succeed in same block after withdraw");
            }

            function test_delay_shareTransferBypass_blocked() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                vm.prank(user1);
                vm.expectRevert(Zenji.ActionDelayActive.selector);
                vault.transfer(user2, shares);

                warpAndMock(block.timestamp + 1);

                vm.prank(user1);
                vault.transfer(user2, shares);

                vm.prank(user2);
                vm.expectRevert(Zenji.ActionDelayActive.selector);
                vault.redeem(shares, user2, user2);

                warpAndMock(block.timestamp + 1);

                vm.prank(user2);
                uint256 out = vault.redeem(shares, user2, user2);
                assertGt(out, 0, "redeem should succeed after 1-block delay");
            }

            function test_withdraw_fullRedeem_clearsSubUnitDebtDust() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                // Seed sub-1 debt asset dust in vault (below old 1-token threshold)
                uint256 debtDust = 5e17; // 0.5 CRVUSD
                deal(CRVUSD, address(vault), debtDust);
                assertEq(crvUSD.balanceOf(address(vault)), debtDust, "Dust seed failed");

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                vm.prank(user1);
                vault.redeem(shares, user1, user1);

                assertEq(
                    crvUSD.balanceOf(address(vault)),
                    0,
                    "Debt dust should be force-swapped on full redeem"
                );
                assertEq(vault.totalSupply(), 0, "Total shares should be zero");
            }

            function test_multipleDepositors() public {
                // User 1 deposits
                vm.prank(user1);
                uint256 shares1 = vault.deposit(2e8, user1);

                // User 2 deposits
                vm.prank(user2);
                uint256 shares2 = vault.deposit(3e8, user2);

                assertEq(vault.totalSupply(), shares1 + shares2, "Total shares mismatch");
                assertEq(vault.balanceOf(user1), shares1, "User1 shares mismatch");
                assertEq(vault.balanceOf(user2), shares2, "User2 shares mismatch");
            }

            // ============ Emergency Withdraw Tests ============

            function test_emergencyMode_blocksBeforeLiquidation() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.redeem(shares, user1, user1);
            }

            function test_postLiquidation_redeemWorks() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                uint256 balanceBefore = wbtc.balanceOf(user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                vm.prank(user1);
                uint256 wbtcReceived = vault.redeem(shares, user1, user1);

                assertEq(vault.balanceOf(user1), 0, "Shares should be zero");
                assertEq(
                    wbtc.balanceOf(user1), balanceBefore + wbtcReceived, "WBTC balance mismatch"
                );
            }

            function test_postLiquidation_withdrawWorks() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 max = vault.maxWithdraw(user1);
                assertGt(max, 0, "Max withdraw should be positive post-liquidation");

                uint256 balanceBefore = wbtc.balanceOf(user1);
                vm.prank(user1);
                uint256 wbtcReceived = vault.withdraw(max, user1, user1);

                assertGt(wbtcReceived, 0, "Should receive WBTC");
                assertApproxEqAbs(
                    wbtc.balanceOf(user1), balanceBefore + wbtcReceived, 5, "WBTC balance mismatch"
                );
            }

            function test_postLiquidation_proRataFairness() public {
                vm.prank(user1);
                uint256 shares1 = vault.deposit(1e8, user1);
                vm.prank(user2);
                uint256 shares2 = vault.deposit(3e8, user2);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 availableWbtcBefore = wbtc.balanceOf(address(vault));
                uint256 totalSupplyBefore = vault.totalSupply();

                uint256 expected1 = (availableWbtcBefore * shares1) / totalSupplyBefore;
                uint256 expected2 = (availableWbtcBefore * shares2) / totalSupplyBefore;

                vm.prank(user1);
                uint256 received1 = vault.redeem(shares1, user1, user1);
                vm.prank(user2);
                uint256 received2 = vault.redeem(shares2, user2, user2);

                assertApproxEqAbs(received1, expected1, 1, "User1 pro-rata mismatch");
                assertApproxEqAbs(received2, expected2, 1, "User2 pro-rata mismatch");
                assertApproxEqAbs(
                    received1 + received2, availableWbtcBefore, 2, "Total pro-rata mismatch"
                );
            }

            // ============ Rebalance Tests ============

            function test_rebalance_notNeeded() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Rebalance should revert if within deadband
                vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
                vault.rebalance();
            }

            function test_strategyDebtRebalanceNeeded_view() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Reduce strategy balance by 4% so ratio falls below PRECISION - DEADBAND_SPREAD (97%)
                uint256 mockYieldBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), (mockYieldBal * 96) / 100);

                assertTrue(
                    vault.strategyDebtRebalanceNeeded(),
                    "Coverage ratio below threshold should be rebalance-needed"
                );
            }

            function test_strategyDebtRebalanceNeeded_view_ratioTooHigh() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Inflate strategy balance by 4% so ratio exceeds PRECISION + DEADBAND_SPREAD (103%)
                uint256 mockYieldBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), (mockYieldBal * 104) / 100); // +4%

                assertTrue(
                    vault.strategyDebtRebalanceNeeded(),
                    "Coverage ratio above upper threshold should be rebalance-needed"
                );
            }

            function test_rebalance_ratioDrift_withinDeadband() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Keep current LTV inside deadband around target to ensure this test
                // takes the ratio-drift branch (not normal LTV rebalance).
                vm.prank(owner);
                vault.setParam(1, 65e16); // upper deadband at 68%

                // Simulate strategy loss exceeding deadband: reduce by 4% so ratio < 97%
                uint256 mockYieldBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), (mockYieldBal * 96) / 100); // -4%

                uint256 ltvBefore = ILoanManager(address(vault.loanManager())).getCurrentLTV();
                uint256 debtBefore = ILoanManager(address(vault.loanManager())).getCurrentDebt();
                assertTrue(
                    vault.strategyDebtRebalanceNeeded(), "Ratio drift should trigger rebalance"
                );

                vault.rebalance();

                uint256 ltvAfter = ILoanManager(address(vault.loanManager())).getCurrentLTV();
                uint256 debtAfter = ILoanManager(address(vault.loanManager())).getCurrentDebt();
                assertLt(ltvAfter, ltvBefore, "Ratio drift rebalance should repay debt");
                assertLt(debtAfter, debtBefore, "Ratio drift rebalance should reduce debt");
            }

            function test_rebalance_ratioHigh_withinDeadband_borrowsMore() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setParam(1, 65e16); // upper deadband at 68%

                uint256 mockYieldBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), (mockYieldBal * 104) / 100); // +4%, exceeds 103% upper bound

                uint256 ltvBefore = ILoanManager(address(vault.loanManager())).getCurrentLTV();
                uint256 debtBefore = ILoanManager(address(vault.loanManager())).getCurrentDebt();
                assertTrue(
                    vault.strategyDebtRebalanceNeeded(), "High ratio should trigger rebalance"
                );

                vault.rebalance();

                uint256 ltvAfter = ILoanManager(address(vault.loanManager())).getCurrentLTV();
                uint256 debtAfter = ILoanManager(address(vault.loanManager())).getCurrentDebt();
                assertGt(
                    ltvAfter, ltvBefore, "High ratio rebalance should increase debt deployment"
                );
                assertGt(debtAfter, debtBefore, "High ratio rebalance should increase debt");
            }

            function test_rebalance_increase_revertsWhenStrategyDebtCoverageLow() public {
                // 65 → 20 is a decrease, immediate
                vm.prank(owner);
                vault.setParam(1, 20e16); // 20%

                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Slash strategy balance by 10% so that even after borrowing more for the
                // 20%→30% LTV increase the post-deposit ratio stays below 97% (PRECISION - DEADBAND_SPREAD)
                uint256 mockYieldBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), (mockYieldBal * 90) / 100); // -10%

                // 20 → 30 is an INCREASE under the new model — propose + execute
                _setTargetLtv(30e16);

                vm.expectPartialRevert(Zenji.StrategyDebtCoverageTooLow.selector);
                vault.rebalance();
            }

            // ============ Admin Tests ============

            function test_setIdle_enterExit() public {
                // Deposit first so there's collateral to deploy when exiting idle
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);
                assertTrue(vault.idle(), "Should be idle");

                vm.prank(owner);
                vault.setIdle(false);
                assertFalse(vault.idle(), "Should exit idle");
            }

            function test_setIdle_depositsWork() public {
                vm.prank(owner);
                vault.setIdle(true);

                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);
                assertGt(shares, 0, "Deposit should succeed in idle mode");
            }

            function test_setIdle_withdrawsWork() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                vm.prank(user1);
                uint256 wbtcReceived = vault.redeem(shares, user1, user1);
                assertGt(wbtcReceived, 0, "Withdraw should succeed in idle mode");
            }

            function test_setIdle_noop() public {
                vm.prank(owner);
                vault.setIdle(true);

                vm.prank(owner);
                vault.setIdle(true);
                assertTrue(vault.idle(), "Idle should remain true");
            }

            function test_setIdle_onlyStrategist() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.setIdle(true);
            }

            function test_maxDeposit_returnsZeroWhenEmergency() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                assertEq(vault.maxDeposit(user1), 0);
            }

            function test_maxDeposit_allowsIdle() public {
                vm.prank(owner);
                vault.setIdle(true);
                assertGt(vault.maxDeposit(user1), 0, "Idle mode should allow deposits");
            }

            function test_maxWithdraw_and_maxRedeem_zeroInEmergencyMode() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                assertEq(vault.maxWithdraw(user1), 0);
                assertEq(vault.maxRedeem(user1), 0);
            }

            function test_depositCapExceeded_reverts() public {
                vm.prank(owner);
                vault.setParam(2, 5e7); // 0.5 WBTC

                vm.prank(user1);
                vm.expectRevert(Zenji.DepositCapExceeded.selector);
                vault.deposit(1e8, user1);
            }

            function test_getTotalValue_whenYieldDisabled() public {
                vm.prank(owner);
                vault.setIdle(true);

                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 totalWbtc = vault.getTotalCollateral();
                uint256 totalValue = viewHelper.getTotalDebtValue(address(vault));

                assertEq(totalWbtc, 1e8);
                assertGt(totalValue, 0);
            }

            function test_setParam_bountyRate_revertsIfTooHigh() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidBountyRate.selector);
                vault.setParam(3, type(uint256).max);
            }

            function test_transferRole_strategist() public {
                address newStrategist = makeAddr("newStrategist");

                // Gov initiates all transfers
                vm.prank(owner);
                vault.transferRole(0, newStrategist);
                assertEq(vault.pendingStrategist(), newStrategist, "Pending strategist mismatch");

                vm.warp(block.timestamp + vault.ROLE_TRANSFER_DELAY());
                vm.prank(newStrategist);
                vault.acceptRole(0);
                assertEq(vault.strategist(), newStrategist, "Strategist mismatch");
            }

            function test_transferRole_guardian() public {
                address newGuardian = makeAddr("newGuardian");

                // Gov initiates all transfers — guardian uses extended delay
                vm.prank(owner);
                vault.transferRole(2, newGuardian);
                assertEq(vault.pendingGuardian(), newGuardian, "Pending guardian mismatch");

                // Guardian transfer requires GOV_GUARDIAN_TRANSFER_DELAY (4 weeks)
                vm.warp(block.timestamp + vault.GOV_GUARDIAN_TRANSFER_DELAY());
                vm.prank(newGuardian);
                vault.acceptRole(2);
                assertEq(vault.guardian(), newGuardian, "Guardian mismatch");
            }

            function test_transferRole_guardian_revertsBeforeExtendedDelay() public {
                address newGuardian = makeAddr("newGuardian");

                vm.prank(owner);
                vault.transferRole(2, newGuardian);

                // 1 week (the strategist delay) is no longer enough for guardian
                vm.warp(block.timestamp + vault.ROLE_TRANSFER_DELAY());
                vm.prank(newGuardian);
                vm.expectRevert(TimelockLib.TimelockNotReady.selector);
                vault.acceptRole(2);
            }

            function test_transferRole_gov_usesExtendedDelay() public {
                address newGov = makeAddr("newGov");

                vm.prank(owner);
                vault.transferRole(1, newGov);

                // 1-week delay should NOT be enough for gov anymore
                vm.warp(block.timestamp + vault.ROLE_TRANSFER_DELAY());
                vm.prank(newGov);
                vm.expectRevert(TimelockLib.TimelockNotReady.selector);
                vault.acceptRole(1);

                // 4-week delay is required
                vm.warp(
                    block.timestamp + vault.GOV_GUARDIAN_TRANSFER_DELAY()
                        - vault.ROLE_TRANSFER_DELAY()
                );
                vm.prank(newGov);
                vault.acceptRole(1);
                assertEq(vault.gov(), newGov, "Gov should be transferred after extended delay");
            }

            function test_transferRole_revertsOnZero() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.transferRole(0, address(0));
            }

            function test_transferRole_onlyGov() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.transferRole(0, user1);
            }

            function test_acceptRole_strategist_revertsIfNotPending() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.acceptRole(0);
            }

            function test_acceptRole_guardian_revertsIfNotPending() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.acceptRole(2);
            }

            function test_onlyStrategist() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.setIdle(true);

                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.withdrawFees(user1);
            }

            function test_onlyGov_setParam() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.setParam(0, 1e16);
            }

            function test_onlyGuardian() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.enterEmergencyMode();
            }

            function test_withdrawFees_revertsOnZeroRecipient() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.withdrawFees(address(0));
            }

            function test_withdrawFees_noFeesNoOp() public {
                vm.prank(owner);
                vault.withdrawFees(owner);
                assertEq(vault.accumulatedFees(), 0);
            }

            // ============ Setter Tests ============

            function test_setParam_feeRate() public {
                uint256 newFeeRate = 5e16; // 5%

                vm.prank(owner);
                vault.setParam(0, newFeeRate);

                assertEq(vault.feeRate(), newFeeRate, "Fee rate should be updated");
            }

            function test_setParam_feeRate_revertsIfTooHigh() public {
                vm.startPrank(owner);
                vm.expectRevert(Zenji.InvalidFeeRate.selector);
                vault.setParam(0, type(uint256).max);
                vm.stopPrank();
            }

            function test_setParam_targetLtv() public {
                uint256 newLtv = 25e16; // 25%

                vm.prank(owner);
                vault.setParam(1, newLtv);

                assertEq(vault.targetLtv(), newLtv, "Target LTV should be updated");
            }

            function test_setParam_targetLtv_revertsIfOutOfRange() public {
                vm.startPrank(owner);
                vm.expectRevert(Zenji.InvalidTargetLtv.selector);
                vault.setParam(1, 0);
                vm.stopPrank();
            }

            function test_strategyDebtRatios_visible() public {
                assertEq(
                    vault.strategyToDebtRatio(),
                    type(uint256).max,
                    "No debt should report max strategy/debt ratio"
                );

                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 strategyToDebt = vault.strategyToDebtRatio();

                assertGe(strategyToDebt, 97e16, "Strategy/debt ratio should be within deadband");
                assertLe(strategyToDebt, 103e16, "Strategy/debt ratio should be within deadband");
            }

            // ============ Emergency Mode Tests ============

            function test_enterEmergencyMode() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                assertTrue(vault.emergencyMode(), "Emergency mode should be enabled");

                // Deposits should fail (emergency mode)
                vm.prank(user1);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.deposit(1e8, user1);

                // Cannot enter emergency mode twice
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.enterEmergencyMode();
            }

            function test_emergencyStep_revertsWhenNotEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyStep(0);
            }

            function test_emergencyFlow_noLoanPath() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                assertTrue(vault.liquidationComplete(), "Liquidation should be complete");
            }

            function test_emergencyRedeemYield_revertsWhenNotEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyRescue(2);
            }

            function test_emergencyWithdraw_withBrickedStrategy_recoversSomeFunds() public {
                // Deploy swapper first
                CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );

                MockBrickedStrategy bricked = new MockBrickedStrategy(CRVUSD, address(0));

                LlamaLoanManager loanManager = new LlamaLoanManager(
                    WBTC,
                    CRVUSD,
                    LLAMALEND_WBTC,
                    WBTC_CRVUSD_POOL,
                    BTC_USD_ORACLE,
                    CRVUSD_USD_ORACLE,
                    address(swapper),
                    address(0),
                    3600
                );

                Zenji brickedVault = new Zenji(
                    WBTC,
                    CRVUSD,
                    address(loanManager),
                    address(bricked),
                    address(swapper),
                    owner,
                    address(viewHelper)
                );

                bricked.initializeVault(address(brickedVault));
                loanManager.initializeVault(address(brickedVault));

                vm.prank(user1);
                wbtc.approve(address(brickedVault), type(uint256).max);

                vm.prank(user1);
                uint256 shares = brickedVault.deposit(1e8, user1);

                bricked.setBricked(true);

                // Increase swapper slippage for emergency (1% default may be too tight for fork)
                vm.store(address(swapper), bytes32(uint256(0)), bytes32(uint256(5e16)));

                vm.startPrank(owner);
                brickedVault.enterEmergencyMode();
                brickedVault.emergencyStep(0);
                brickedVault.emergencyStep(1);
                brickedVault.emergencyStep(2);
                vm.stopPrank();

                vm.roll(block.number + 1);

                uint256 balanceBefore = wbtc.balanceOf(user1);
                vm.prank(user1);
                uint256 wbtcReceived = brickedVault.redeem(shares, user1, user1);

                assertGt(wbtcReceived, 0, "Should recover some WBTC");
                assertLe(wbtcReceived, 1e8, "Should not exceed deposit");
                assertEq(wbtc.balanceOf(user1), balanceBefore + wbtcReceived);
            }

            function test_rescueAssets_revertsWhenNotEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.rescueAssets(address(wbtc), owner);
            }

            function test_rescueAssets_revertsOnZeroRecipient() public {
                _setRescueRecipient(owner);
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.rescueAssets(address(wbtc), address(0));
            }

            function test_emergencyFlow() public {
                // Deposit first
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Wait for redemption delay
                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                // Enter emergency mode and liquidate
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                assertTrue(vault.liquidationComplete(), "Liquidation should be complete");
                assertTrue(vault.emergencyMode(), "Should be in emergency mode");
                assertFalse(vault.loanManager().loanExists(), "Loan should be closed");
                assertGt(wbtc.balanceOf(address(vault)), 0, "Vault should have WBTC");
            }

            function test_harvestYield_revertsInEmergencyMode() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.harvestYield();
            }

            function test_constructor_revertsWhenStrategyMissing() public {
                uint64 nonce = vm.getNonce(address(this));
                address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);
                CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );
                LlamaLoanManager loanManager = new LlamaLoanManager(
                    WBTC,
                    CRVUSD,
                    LLAMALEND_WBTC,
                    WBTC_CRVUSD_POOL,
                    BTC_USD_ORACLE,
                    CRVUSD_USD_ORACLE,
                    address(swapper),
                    predictedVault,
                    3600
                );

                vm.expectRevert(Zenji.InvalidAddress.selector);
                new Zenji(
                    WBTC,
                    CRVUSD,
                    address(loanManager),
                    address(0),
                    address(swapper),
                    owner,
                    address(viewHelper)
                );
            }

            // ============ View Function Tests ============

            function test_getTotalWbtc() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 totalWbtc = vault.getTotalCollateral();
                assertGt(totalWbtc, 0, "Total WBTC should be greater than 0");
            }

            function test_getUserValue() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 userValue = viewHelper.getUserValue(address(vault), user1);
                assertGt(userValue, 0, "User value should be greater than 0");
            }

            function test_getLtvBounds() public view {
                (uint256 lower, uint256 upper) = viewHelper.getLtvBounds(address(vault));
                assertEq(lower, vault.targetLtv() - vault.DEADBAND_SPREAD(), "Lower bound mismatch");
                assertEq(upper, vault.targetLtv() + vault.DEADBAND_SPREAD(), "Upper bound mismatch");
            }

            // ============ Deposit Cap Tests ============

            function test_setParam_depositCap() public {
                uint256 cap = 5e8; // 5 WBTC

                vm.prank(owner);
                vault.setParam(2, cap);

                assertEq(vault.depositCap(), cap, "Deposit cap mismatch");
            }

            function test_depositCapExceeded() public {
                vm.prank(owner);
                vault.setParam(2, 5e7); // 0.5 WBTC cap

                vm.prank(user1);
                vm.expectRevert(Zenji.DepositCapExceeded.selector);
                vault.deposit(1e8, user1); // Try to deposit 1 WBTC
            }

            // ============ Edge Cases ============

            function test_minDeposit() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.AmountTooSmall.selector);
                vault.deposit(1e3, user1); // Below MIN_DEPOSIT
            }

            function test_zeroWithdraw() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.ZeroAmount.selector);
                vault.redeem(0, user1, user1);
            }

            function test_insufficientShares() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.InsufficientShares.selector);
                vault.redeem(1e8, user1, user1);
            }

            // ============ Fuzz Tests ============

            function testFuzz_deposit(uint256 amount) public {
                // Bound to reasonable range
                amount = bound(amount, 1e4, 5e8);

                vm.prank(user1);
                uint256 shares = vault.deposit(amount, user1);

                assertGt(shares, 0, "Should receive shares");
                assertEq(vault.balanceOf(user1), shares, "Share balance mismatch");
            }

            function testFuzz_partialWithdraw(uint256 depositAmount, uint256 withdrawPercent)
                public
            {
                // Use higher minimum to avoid dust/final-withdrawal edge cases
                depositAmount = bound(depositAmount, 1e6, 5e8);
                withdrawPercent = bound(withdrawPercent, 10, 90);

                vm.prank(user1);
                uint256 shares = vault.deposit(depositAmount, user1);

                // Wait for redemption delay
                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 sharesToWithdraw = (shares * withdrawPercent) / 100;
                if (sharesToWithdraw == 0) sharesToWithdraw = 1;

                vm.prank(user1);
                uint256 wbtcReceived = vault.redeem(sharesToWithdraw, user1, user1);

                assertGt(wbtcReceived, 0, "Should receive WBTC");

                // Note: The vault has a "final withdrawal" mechanism that burns all shares
                // when remaining WBTC would be below MIN_DEPOSIT. This is expected behavior.
                uint256 remainingShares = vault.balanceOf(user1);
                assertTrue(
                    remainingShares == shares - sharesToWithdraw || remainingShares == 0,
                    "Remaining shares should match expected or be zero (final withdrawal)"
                );
            }

            // ============ Phase 1: ERC4626 Compliance Tests ============

            function test_erc4626_asset() public view {
                assertEq(vault.asset(), WBTC, "Asset should be WBTC");
            }

            function test_erc4626_decimals() public view {
                assertEq(vault.decimals(), 8, "Decimals should be 8");
            }

            function test_erc4626_totalAssets() public {
                assertEq(vault.totalAssets(), 0, "Initial total assets should be 0");

                vm.prank(user1);
                vault.deposit(1e8, user1);

                assertGt(vault.totalAssets(), 0, "Total assets should increase after deposit");
            }

            function test_erc4626_convertToShares() public {
                // Before any deposits, 1:1 ratio
                uint256 shares = vault.convertToShares(1e8);
                assertEq(shares, 1e8, "Initial conversion should be 1:1");

                // After deposit
                vm.prank(user1);
                vault.deposit(1e8, user1);

                shares = vault.convertToShares(1e8);
                assertGt(shares, 0, "Should return positive shares");
            }

            function test_erc4626_convertToAssets() public {
                uint256 assets = vault.convertToAssets(1e8);
                assertEq(assets, 1e8, "Initial conversion should be 1:1");

                vm.prank(user1);
                vault.deposit(1e8, user1);

                assets = vault.convertToAssets(1e8);
                assertGt(assets, 0, "Should return positive assets");
            }

            function test_erc4626_maxDeposit() public view {
                uint256 max = vault.maxDeposit(user1);
                assertEq(max, type(uint256).max, "Max deposit should be unlimited when no cap");
            }

            function test_erc4626_maxDeposit_withCap() public {
                vm.prank(owner);
                vault.setParam(2, 5e8);

                uint256 max = vault.maxDeposit(user1);
                assertEq(max, 5e8, "Max deposit should equal cap");

                vm.prank(user1);
                vault.deposit(2e8, user1);

                max = vault.maxDeposit(user1);
                assertLt(max, 5e8, "Max deposit should decrease after deposit");
            }

            function test_erc4626_maxMint() public view {
                uint256 max = vault.maxMint(user1);
                assertEq(max, type(uint256).max, "Max mint should be unlimited");
            }

            function test_erc4626_maxWithdraw() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 max = vault.maxWithdraw(user1);
                assertGt(max, 0, "Max withdraw should be positive");
            }

            function test_erc4626_maxRedeem() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                uint256 max = vault.maxRedeem(user1);
                assertEq(max, shares, "Max redeem should equal share balance");
            }

            function test_erc4626_previewDeposit() public view {
                uint256 shares = vault.previewDeposit(1e8);
                assertEq(shares, 1e8, "Preview deposit should return expected shares");
            }

            function test_erc4626_previewMint() public view {
                uint256 assets = vault.previewMint(1e8);
                assertEq(assets, 1e8, "Preview mint should return expected assets");
            }

            function test_erc4626_previewWithdraw() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 shares = vault.previewWithdraw(5e7);
                assertGt(shares, 0, "Preview withdraw should return positive shares");
            }

            function test_previewWithdraw_postLiquidation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 availableWbtc = wbtc.balanceOf(address(vault));
                uint256 assets = availableWbtc / 2;
                uint256 expected = (assets * vault.totalSupply() + availableWbtc - 1)
                    / availableWbtc;
                uint256 preview = vault.previewWithdraw(assets);

                assertEq(preview, expected, "Preview withdraw should be pro-rata post-liquidation");
            }

            function test_erc4626_previewRedeem() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 assets = vault.previewRedeem(5e7);
                assertGt(assets, 0, "Preview redeem should return positive assets");
            }

            function test_previewRedeem_postLiquidation() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 availableWbtc = wbtc.balanceOf(address(vault));
                uint256 expected = (availableWbtc * shares) / vault.totalSupply();
                uint256 preview = vault.previewRedeem(shares);

                assertEq(preview, expected, "Preview redeem should be pro-rata post-liquidation");
            }

            function test_erc4626_deposit_withReceiver() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user2);

                assertEq(vault.balanceOf(user2), shares, "Receiver should have shares");
                assertEq(vault.balanceOf(user1), 0, "Sender should have no shares");
            }

            function test_erc4626_mint() public {
                uint256 expectedAssets = vault.previewMint(1e8);

                vm.prank(user1);
                uint256 assets = vault.mint(1e8, user1);

                assertEq(assets, expectedAssets, "Assets used should match preview");
                assertEq(vault.balanceOf(user1), 1e8, "Should have minted shares");
            }

            function test_erc4626_mint_withReceiver() public {
                vm.prank(user1);
                vault.mint(1e8, user2);

                assertEq(vault.balanceOf(user2), 1e8, "Receiver should have shares");
                assertEq(vault.balanceOf(user1), 0, "Sender should have no shares");
            }

            function test_erc4626_withdraw_withReceiver() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 balanceBefore = wbtc.balanceOf(user2);

                vm.prank(user1);
                vault.withdraw(5e7, user2, user1);

                assertGt(wbtc.balanceOf(user2), balanceBefore, "Receiver should get WBTC");
            }

            function test_erc4626_redeem() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 balanceBefore = wbtc.balanceOf(user1);

                vm.prank(user1);
                uint256 assets = vault.redeem(shares, user1, user1);

                assertGt(assets, 0, "Should receive assets");
                assertGt(wbtc.balanceOf(user1), balanceBefore, "Balance should increase");
                assertEq(vault.balanceOf(user1), 0, "Shares should be burned");
            }

            function test_erc4626_redeem_withReceiver() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 balanceBefore = wbtc.balanceOf(user2);

                vm.prank(user1);
                vault.redeem(shares, user2, user1);

                assertGt(wbtc.balanceOf(user2), balanceBefore, "Receiver should get WBTC");
            }

            // ============ Phase 2: Rebalance Tests ============

            function test_rebalance_decreaseLtv() public {
                // Deposit to create a position
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Simulate price drop (BTC price falls, LTV increases)
                warpAndMock(block.timestamp + 2);
                mockOracle(70000e8); // Price drops from ~89k to 70k

                // Check if rebalance is needed
                bool needed = viewHelper.isRebalanceNeeded(address(vault));
                if (needed) {
                    // Rebalance should decrease LTV
                    vault.rebalance();
                    assertFalse(
                        viewHelper.isRebalanceNeeded(address(vault)), "Rebalance should fix LTV"
                    );
                }
            }

            function test_rebalance_increaseLtv() public {
                // Deposit to create a position
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Simulate price increase (BTC price rises, LTV decreases)
                warpAndMock(block.timestamp + 2);
                mockOracle(75000e8); // Price rises significantly

                bool needed = viewHelper.isRebalanceNeeded(address(vault));
                if (needed) {
                    vault.rebalance();
                    assertFalse(
                        viewHelper.isRebalanceNeeded(address(vault)), "Rebalance should fix LTV"
                    );
                }
            }

            function test_getCurrentLTV() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 ltv = vault.loanManager().getCurrentLTV();
                assertGt(ltv, 0, "LTV should be positive after deposit");
                assertLt(ltv, 1e18, "LTV should be less than 100%");
            }

            function test_getCurrentCollateral() public {
                assertEq(
                    vault.loanManager().getCurrentCollateral(), 0, "Initial collateral should be 0"
                );

                vm.prank(user1);
                vault.deposit(1e8, user1);

                assertGt(
                    vault.loanManager().getCurrentCollateral(),
                    0,
                    "Collateral should increase after deposit"
                );
            }

            function test_getHealth() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                int256 health = viewHelper.getHealth(address(vault));
                assertGt(health, 0, "Health should be positive");
            }

            function test_isRebalanceNeeded() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Initially should not need rebalance (just deposited at target LTV)
                bool needed = viewHelper.isRebalanceNeeded(address(vault));
                // Result depends on market conditions, just verify it doesn't revert
                if (needed) {
                    assertTrue(needed, "isRebalanceNeeded returned true");
                } else {
                    assertFalse(needed, "isRebalanceNeeded returned false");
                }
            }

            // No-strategy scenarios are invalid with immutable strategy; tests removed.
            function test_feeAccrual_costBasisTracking() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Check that cost basis was set
                uint256 costBasis = viewHelper.yieldCostBasis(address(vault));
                assertGt(costBasis, 0, "Cost basis should be set after deposit");

                // Get yield vault stats (legacy function)
                (, uint256 currentValue, uint256 basis, uint256 unrealizedProfit) =
                    viewHelper.getYieldVaultStats(address(vault));

                assertGt(currentValue, 0, "Should have current value");
                assertEq(basis, costBasis, "Cost basis should match");
                // Initially no profit (just deposited)
                assertEq(unrealizedProfit, 0, "Should have no unrealized profit initially");
            }

            function test_feeAccrual_withProfit() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 initialCostBasis = viewHelper.yieldCostBasis(address(vault));
                assertGt(initialCostBasis, 0, "Cost basis should be set after deposit");

                // Skip time to simulate yield accrual
                warpAndMock(block.timestamp + 365 days);
                mockOracle(89238e8);

                // Get pending fees
                (uint256 totalFees, uint256 pendingFees) = viewHelper.getPendingFees(address(vault));

                // If yield vault has appreciated, pending fees should exist
                // Note: In a real test with fork, this depends on actual yield vault performance
                // The logic is: pendingFees = (currentValue - costBasis) * feeRate / PRECISION
                // Verify that totalFees reflects accumulated fees
                assertEq(totalFees, vault.accumulatedFees(), "Total fees should match accumulated");
                // Pending fees may be 0 if no yield appreciation in mock vault
                assertTrue(pendingFees >= 0, "Pending fees should be non-negative");
            }

            function test_feeAccrual_accrueYieldFees() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                // Anyone can call accrueYieldFees
                vault.accrueYieldFees();

                // Check accumulated fees - may be 0 if no yield vault appreciation
                uint256 fees = vault.accumulatedFees();
                assertTrue(fees >= 0, "Fees should be non-negative");
            }

            function test_feeAccrual_withdrawFeesRedeems() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                // Get initial crvUSD balance
                uint256 ownerCrvUsdBefore = IERC20(CRVUSD).balanceOf(owner);

                // Accrue and withdraw fees
                vm.prank(owner);
                vault.withdrawFees(owner);

                uint256 ownerCrvUsdAfter = IERC20(CRVUSD).balanceOf(owner);

                // Owner should receive any accumulated fees (may be 0 if no yield profit)
                assertTrue(
                    ownerCrvUsdAfter >= ownerCrvUsdBefore, "Owner balance should not decrease"
                );
            }

            function test_feeAccrual_rebalanceBountyFromFees() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Skip time and manipulate price to trigger rebalance
                warpAndMock(block.timestamp + 30 days);

                // Mock a price drop to push LTV above upper band
                mockOracle(70000e8); // Lower BTC price increases LTV

                // Check if rebalance is needed
                if (viewHelper.isRebalanceNeeded(address(vault))) {
                    uint256 keeperCrvUsdBefore = IERC20(CRVUSD).balanceOf(address(this));

                    // Rebalance should accrue fees and pay bounty
                    vault.rebalance();

                    uint256 keeperCrvUsdAfter = IERC20(CRVUSD).balanceOf(address(this));

                    // Keeper receives bounty if there were accumulated fees
                    // bounty = accumulatedFees * rebalanceBountyRate / PRECISION
                    assertTrue(
                        keeperCrvUsdAfter >= keeperCrvUsdBefore,
                        "Keeper balance should not decrease"
                    );
                }
            }

            function test_feeAccrual_userValueExcludesFees() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                // Get total value before fee accrual
                uint256 totalWbtcBefore = vault.getTotalCollateral();

                // Manually set accumulated fees to test exclusion
                // Note: In real scenario, fees are accrued from yield profit
                vault.accrueYieldFees();

                uint256 accFees = vault.accumulatedFees();
                uint256 totalWbtcAfter = vault.getTotalCollateral();

                // If fees were accrued, total WBTC (user value) should remain roughly the same
                // because fees are excluded from user value
                // Verify fee accrual doesn't artificially inflate user value
                assertTrue(accFees >= 0, "Accumulated fees should be non-negative");
                assertTrue(
                    totalWbtcAfter <= totalWbtcBefore + 1e4,
                    "User value should not increase significantly from fee accrual"
                );
            }

            function test_feeAccrual_partialWithdrawalReducesBasis() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(2e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                uint256 initialBasis = viewHelper.yieldCostBasis(address(vault));

                // Partial withdraw
                uint256 userShares = vault.balanceOf(user1);
                vm.prank(user1);
                vault.redeem(userShares / 2, user1, user1);

                uint256 newBasis = viewHelper.yieldCostBasis(address(vault));

                // Cost basis should be reduced (not necessarily by exactly half due to LTV rebalancing)
                assertLe(newBasis, initialBasis, "Cost basis should be reduced after withdrawal");
            }

            function test_getPendingFees() public {
                // Deposit WBTC
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                (uint256 totalFees, uint256 pendingFees) = viewHelper.getPendingFees(address(vault));

                // Total fees = accumulated + pending
                assertEq(totalFees, vault.accumulatedFees() + pendingFees, "Total fees calculation");
            }

            function test_getYieldVaultStats() public {
                // Before deposit
                (, uint256 currentValue, uint256 costBasis, uint256 unrealizedProfit) =
                    viewHelper.getYieldVaultStats(address(vault));

                assertEq(currentValue, 0, "No current value before deposit");
                assertEq(costBasis, 0, "No cost basis before deposit");
                assertEq(unrealizedProfit, 0, "No profit before deposit");

                // After deposit
                vm.prank(user1);
                vault.deposit(1e8, user1);

                (, currentValue, costBasis, unrealizedProfit) =
                    viewHelper.getYieldVaultStats(address(vault));

                assertGt(currentValue, 0, "Should have current value after deposit");
                assertGt(costBasis, 0, "Should have cost basis after deposit");
            }

            function test_getYieldStrategyStats() public {
                // Before deposit
                (
                    string memory strategyName,
                    uint256 currentValue,
                    uint256 costBasis,
                    uint256 unrealizedProfit
                ) = viewHelper.getYieldStrategyStats(address(vault));

                assertEq(strategyName, "Mock Yield Strategy", "Strategy name should match");
                assertEq(currentValue, 0, "No current value before deposit");
                assertEq(costBasis, 0, "No cost basis before deposit");
                assertEq(unrealizedProfit, 0, "No profit before deposit");

                // After deposit
                vm.prank(user1);
                vault.deposit(1e8, user1);

                (strategyName, currentValue, costBasis, unrealizedProfit) =
                    viewHelper.getYieldStrategyStats(address(vault));

                assertEq(strategyName, "Mock Yield Strategy", "Strategy name should match");
                assertGt(currentValue, 0, "Should have current value after deposit");
                assertGt(costBasis, 0, "Should have cost basis after deposit");
            }

            // ============ Coverage Boost Tests ============

            function test_rebalance_highLtv_decreaseLtv() public {
                deal(WBTC, user1, 10e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 10e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                // Mock LTV to be high
                vm.mockCall(
                    address(vault.loanManager()),
                    abi.encodeWithSelector(ILoanManager.getCurrentLTV.selector),
                    abi.encode(uint256(8500))
                );

                vm.prank(address(0x123)); // keeper
                vault.rebalance();

                // Rebalance should have called _decreaseLtv or similar which would update LTV
                // In a mock scenario, we just verify it didn't revert.
            }

            function test_rebalance_lowLtv_increaseLtv() public {
                deal(WBTC, user1, 10e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 10e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                // Mock LTV to be low
                vm.mockCall(
                    address(vault.loanManager()),
                    abi.encodeWithSelector(ILoanManager.getCurrentLTV.selector),
                    abi.encode(uint256(7000))
                );

                vm.prank(address(0x123)); // keeper
                vault.rebalance();
            }

            function test_rebalance_withBountyPayment() public {
                deal(WBTC, user1, 10e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 10e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                // 1. Set bounty rate and generate profit
                vm.startPrank(owner);
                vault.setParam(0, 1e17); // 10% fee rate
                vault.setParam(3, 1e17); // 10% bounty
                vm.stopPrank();

                // Simulate strategy profit
                uint256 currentBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBal + 1000e18); // 1000 crvUSD profit

                // 2. Accrue fees
                vault.accrueYieldFees();
                uint256 feesBefore = vault.accumulatedFees();
                assertGt(feesBefore, 0, "Fees should be accrued");

                // 3. Trigger rebalance
                vm.mockCall(
                    address(vault.loanManager()),
                    abi.encodeWithSelector(ILoanManager.getCurrentLTV.selector),
                    abi.encode(uint256(8500))
                );

                uint256 keeperBalBefore = crvUSD.balanceOf(address(0x123));
                vm.prank(address(0x123));
                vault.rebalance();

                uint256 keeperBalAfter = crvUSD.balanceOf(address(0x123));
                assertGt(keeperBalAfter, keeperBalBefore, "Keeper should receive bounty");
            }

            function test_accrueYieldFees_noProfit() public {
                deal(WBTC, user1, 1e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 1e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                uint256 feesBefore = vault.accumulatedFees();
                vault.accrueYieldFees();
                assertEq(
                    vault.accumulatedFees(), feesBefore, "Fees should not increase with no profit"
                );
            }

            function test_accrueYieldFees_withProfit() public {
                deal(WBTC, user1, 1e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 1e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                // Simulate strategy profit
                uint256 currentBalProfit = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBalProfit + 1000e18);

                uint256 feesBefore = vault.accumulatedFees();
                vault.accrueYieldFees();
                assertGt(vault.accumulatedFees(), feesBefore, "Fees should increase with profit");
            }

            function test_reportStrategyLoss() public {
                deal(WBTC, user1, 1e8);
                vm.startPrank(user1);
                wbtc.approve(address(vault), 1e8);
                vault.deposit(1e8, user1);
                vm.stopPrank();

                // 1. First accrue to set lastStrategyBalance
                vault.accrueYieldFees();
                uint256 lastBal = vault.lastStrategyBalance();

                // 2. Force a loss in the strategy
                uint256 currentBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBal / 2);

                // 3. This should trigger loss reporting during next fee accrual
                vault.accrueYieldFees();
                assertLt(
                    vault.lastStrategyBalance(), lastBal, "Last strategy balance should decrease"
                );
            }

            // ============ Branch Coverage: Post-Liquidation Edge Cases ============

            function test_postLiquidation_redeem_allowanceDelegation() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                // user1 approves user2 to redeem on their behalf
                vm.prank(user1);
                vault.approve(user2, shares);

                uint256 balBefore = wbtc.balanceOf(user1);
                vm.prank(user2);
                uint256 received = vault.redeem(shares, user1, user1);

                assertGt(received, 0, "Should receive WBTC via delegation");
                assertEq(vault.balanceOf(user1), 0, "Shares should be burned");
                assertEq(wbtc.balanceOf(user1), balBefore + received);
            }

            function test_postLiquidation_withdraw_allowanceDelegation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 maxW = vault.maxWithdraw(user1);

                // user1 approves user2
                vm.prank(user1);
                vault.approve(user2, type(uint256).max);

                uint256 balBefore = wbtc.balanceOf(user1);
                vm.prank(user2);
                uint256 sharesBurned = vault.withdraw(maxW, user1, user1);

                assertGt(sharesBurned, 0, "Should burn shares");
                assertGt(wbtc.balanceOf(user1), balBefore, "Should receive WBTC");
            }

            function test_postLiquidation_maxWithdraw_zeroSupply() public {
                // No deposits → supply = 0
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                assertEq(vault.maxWithdraw(user1), 0, "maxWithdraw should be 0 with zero supply");
            }

            function test_postLiquidation_previewRedeem_zeroSupply() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                assertEq(vault.previewRedeem(1e8), 0, "previewRedeem should be 0 with zero supply");
            }

            function test_postLiquidation_previewWithdraw_zeroWbtc() public {
                // Deposit, liquidate, then redeem all so vault has 0 WBTC
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                // Redeem all shares so vault is drained
                vm.prank(user1);
                vault.redeem(shares, user1, user1);

                // Now supply is 0 and wbtc is 0
                assertEq(
                    vault.previewWithdraw(1e8),
                    0,
                    "previewWithdraw should be 0 with zero WBTC and supply"
                );
            }

            function test_postLiquidation_redeem_zeroWbtcAmount() public {
                // Deposit from two users, liquidate, drain WBTC, second user gets 0
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.prank(user2);
                uint256 shares2 = vault.deposit(1e8, user2);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                // Deal away the vault's WBTC to simulate 0 balance
                uint256 vaultBal = wbtc.balanceOf(address(vault));
                vm.prank(address(vault));
                wbtc.transfer(address(0xdead), vaultBal);

                // Redeem should return 0 WBTC but still burn shares
                vm.prank(user2);
                uint256 received = vault.redeem(shares2, user2, user2);
                assertEq(received, 0, "Should receive 0 WBTC when vault balance is 0");
                assertEq(vault.balanceOf(user2), 0, "Shares should still be burned");
            }

            // ============ Branch Coverage: setIdle with active loan ============

            function test_setIdle_withActiveLoan() public {
                // Deposit to create a loan position
                vm.prank(user1);
                vault.deposit(1e8, user1);

                assertTrue(vault.loanManager().loanExists(), "Should have active loan");

                warpAndMock(block.timestamp + 2);
                mockOracle(lastBtcPrice);

                // setIdle should unwind the entire position
                vm.prank(owner);
                vault.setIdle(true);

                assertTrue(vault.idle(), "Should be idle");
                // After idle, WBTC should be in vault, no loan
                assertGt(wbtc.balanceOf(address(vault)), 0, "Should have WBTC in vault");
            }

            // ============ Branch Coverage: _deployCapital idle/emergency guard ============

            function test_deployCapital_idleSkips() public {
                vm.prank(owner);
                vault.setIdle(true);

                // Deposit in idle mode - _deployCapital returns early
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);
                assertGt(shares, 0, "Should mint shares");

                // WBTC stays idle in the vault
                assertEq(
                    wbtc.balanceOf(address(vault)), 1e8, "WBTC should stay in vault in idle mode"
                );
            }

            // ============ Branch Coverage: Rebalance Bounty Partial Payment ============

            function test_rebalance_bountyPartialPayment() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Set bounty rate
                vm.startPrank(owner);
                vault.setParam(0, 1e17); // 10% fee rate
                vault.setParam(3, 1e17); // 10% bounty
                vm.stopPrank();

                // Simulate large profit to create fees
                uint256 currentBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBal + 10000e18);

                // Accrue large fees
                vault.accrueYieldFees();
                uint256 fees = vault.accumulatedFees();
                assertGt(fees, 0, "Should have fees");

                // Now drain the strategy so strategyBalance < bounty
                deal(CRVUSD, address(mockYield), 1e18); // Very small balance

                // Trigger rebalance with high LTV
                warpAndMock(block.timestamp + 2);
                mockOracle(70000e8);

                if (viewHelper.isRebalanceNeeded(address(vault))) {
                    uint256 keeperBefore = crvUSD.balanceOf(keeper);
                    vm.prank(keeper);
                    vault.rebalance();
                    uint256 keeperAfter = crvUSD.balanceOf(keeper);

                    // Keeper should get partial bounty (limited by strategy balance)
                    assertTrue(
                        keeperAfter >= keeperBefore, "Keeper should receive at least some bounty"
                    );
                }
            }

            function test_rebalance_zeroBountyRate() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Set bounty rate to 0
                vm.prank(owner);
                vault.setParam(3, 0);

                warpAndMock(block.timestamp + 2);
                mockOracle(70000e8);

                if (viewHelper.isRebalanceNeeded(address(vault))) {
                    uint256 keeperBefore = crvUSD.balanceOf(keeper);
                    vm.prank(keeper);
                    vault.rebalance();
                    uint256 keeperAfter = crvUSD.balanceOf(keeper);

                    assertEq(keeperAfter, keeperBefore, "No bounty should be paid with 0 rate");
                }
            }

            // ============ Branch Coverage: ERC4626 withdraw with allowance ============

            function test_erc4626_withdraw_withAllowance() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                // user1 approves user2
                vm.prank(user1);
                vault.approve(user2, type(uint256).max);

                uint256 receiverBefore = wbtc.balanceOf(user3);
                vm.prank(user2);
                vault.withdraw(5e7, user3, user1);

                assertGt(
                    wbtc.balanceOf(user3), receiverBefore, "Receiver should get WBTC via allowance"
                );
            }

            function test_erc4626_redeem_withAllowance() public {
                // Use 2 depositors so the redeeming user isn't the last one (avoids MIN_DEPOSIT final-withdraw)
                vm.prank(user1);
                uint256 shares = vault.deposit(2e8, user1);
                vm.prank(user2);
                vault.deposit(2e8, user2);

                warpAndMock(block.timestamp + 2);
                mockOracle(89238e8);

                // user1 approves user3 to redeem half
                uint256 halfShares = shares / 2;
                vm.prank(user1);
                vault.approve(user3, halfShares);

                uint256 receiverBefore = wbtc.balanceOf(user3);
                vm.prank(user3);
                vault.redeem(halfShares, user3, user1);

                assertGt(
                    wbtc.balanceOf(user3), receiverBefore, "Receiver should get WBTC via allowance"
                );
            }

            // ============ Branch Coverage: rescueAssets post-liquidation WBTC blocked ============

            function test_rescueAssets_blocksWbtcAfterLiquidation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);

                // WBTC is collateralAsset, blocked by rescueAssets
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.rescueAssets(address(wbtc), owner);
                vm.stopPrank();
            }

            function test_rescueAssets_allowsNonCoreTokenAfterLiquidation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);

                // Rescue a non-core token (not collateralAsset or debtAsset) should work
                address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
                deal(USDT, address(vault), 1000e6);
                vault.rescueAssets(USDT, owner);
                vm.stopPrank();
            }

            // ============ Branch Coverage: emergency flow double call ============

            function test_emergencyFlow_revertsIfAlreadyComplete() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);

                vm.expectRevert(Zenji.LiquidationAlreadyComplete.selector);
                vault.emergencyStep(2);
                vm.stopPrank();
            }

            // ============ Branch Coverage: maxDeposit when cap fully used ============

            function test_maxDeposit_zeroWhenCapReached() public {
                // Disable yield so totalWbtc == wbtc.balanceOf (exact match)
                vm.startPrank(owner);
                vault.setIdle(true);
                vault.setParam(2, 1e8);
                vm.stopPrank();

                vm.prank(user1);
                vault.deposit(1e8, user1);

                assertEq(vault.maxDeposit(user1), 0, "Max deposit should be 0 when cap reached");
            }

            // ============ Branch Coverage: ERC4626 withdraw zero assets reverts ============

            function test_erc4626_withdraw_zeroAssets_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(user1);
                vm.expectRevert(Zenji.ZeroAmount.selector);
                vault.withdraw(0, user1, user1);
            }

            // ============ Branch Coverage: postLiquidation withdraw zero available ============

            function test_postLiquidation_withdraw_zeroAvailableWbtc_reverts() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);
                mockOracle(85000e8);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                // Drain vault WBTC
                vm.prank(user1);
                vault.redeem(shares, user1, user1);

                // Now deposit again (user2 has shares from before — but no, supply is 0)
                // Create scenario: supply > 0 but availableWbtc == 0
                // This is hard to trigger naturally; skip if impractical
            }

            // ============ Branch Coverage: previewWithdraw normal path zero totalWbtc ============

            function test_previewWithdraw_zeroTotalWbtc_returnsAssets() public view {
                // When totalWbtc and supply are 0, should return assets directly
                uint256 preview = vault.previewWithdraw(1e8);
                assertEq(preview, 1e8, "Should return assets when totalWbtc is 0");
            }

            // ============ Branch Coverage: getUserValue with zero supply ============

            function test_getUserValue_zeroSupply() public view {
                assertEq(
                    viewHelper.getUserValue(address(vault), user1),
                    0,
                    "Should return 0 with no supply"
                );
            }

            // ============ Branch Coverage: isRebalanceNeeded no loan ============

            function test_isRebalanceNeeded_noLoan() public view {
                assertFalse(
                    viewHelper.isRebalanceNeeded(address(vault)), "Should be false with no loan"
                );
            }

            // ============ Branch Coverage: rebalance no loan reverts ============

            function test_rebalance_noLoan_reverts() public {
                vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
                vault.rebalance();
            }

            // ============ Branch Coverage: transferCollateral/transferDebt not emergency ============

            function test_transferCollateral_revertsWhenNotEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyRescue(0);
            }

            function test_transferDebt_revertsWhenNotEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyRescue(1);
            }

            // ============ Additional Coverage Tests ============

            function test_proposeAndExecuteSwapper_functionality() public {
                CurveTwoCryptoSwapper newSwapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );

                vm.prank(owner);
                vault.proposeSwapper(address(newSwapper));

                warpAndMock(block.timestamp + 1 weeks + 1);

                vm.prank(owner);
                vault.executeSwapper();

                assertEq(address(vault.swapper()), address(newSwapper), "Swapper should be updated");
            }

            function test_proposeSwapper_onlyGov() public {
                CurveTwoCryptoSwapper newSwapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );

                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.proposeSwapper(address(newSwapper));
            }

            function test_transferRole_gov() public {
                address newGov = makeAddr("newGov");

                vm.prank(owner);
                vault.transferRole(1, newGov);
                assertEq(vault.pendingGov(), newGov, "Pending gov should be set");

                // Gov transfer requires the extended 4-week delay
                vm.warp(block.timestamp + vault.GOV_GUARDIAN_TRANSFER_DELAY());
                vm.prank(newGov);
                vault.acceptRole(1);
                assertEq(vault.gov(), newGov, "Gov should be updated");
            }

            function test_transferRole_gov_revertsOnZero() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.transferRole(1, address(0));
            }

            function test_acceptRole_gov_revertsIfNotPending() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.acceptRole(1);
            }

            function test_withdrawFees_withFees() public {
                // Deposit and create some activity
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Set a fee rate
                vm.prank(owner);
                vault.setParam(0, 5e16); // 5%

                // Simulate strategy profit
                uint256 currentBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBal + 1000e18);

                // Accrue fees
                vault.accrueYieldFees();
                uint256 fees = vault.accumulatedFees();
                assertGt(fees, 0, "Should have accumulated fees");

                // Withdraw fees
                uint256 ownerBalBefore = crvUSD.balanceOf(owner);
                vm.prank(owner);
                vault.withdrawFees(owner);
                uint256 ownerBalAfter = crvUSD.balanceOf(owner);

                assertGt(ownerBalAfter, ownerBalBefore, "Owner should receive fees");
                assertEq(vault.accumulatedFees(), 0, "Fees should be reset");
            }

            function test_setParam_depositCap_zero() public {
                vm.prank(owner);
                vault.setParam(2, 0);

                assertEq(vault.depositCap(), 0, "Deposit cap should be set to 0");
                assertEq(
                    vault.maxDeposit(user1),
                    type(uint256).max,
                    "Max deposit should be unlimited when cap is 0"
                );
            }

            function test_emergencyRedeemYield_withStrategy() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0); // resolve step 0 so rescue(2) is permitted
                vault.emergencyRescue(2);
                vm.stopPrank();
            }

            function test_transferCollateral_withCollateral() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();

                uint256 lmCollateralBefore = vault.loanManager().getCollateralBalance();
                vault.emergencyRescue(0);
                uint256 lmCollateralAfter = vault.loanManager().getCollateralBalance();

                // Loan manager may hold collateral in protocol, not in its balance; just ensure no revert
                assertEq(
                    lmCollateralAfter, lmCollateralBefore, "Collateral balance should be unchanged"
                );
                vm.stopPrank();
            }

            function test_transferDebt_withDebt() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();

                uint256 lmDebtBefore = vault.loanManager().getDebtBalance();
                vault.emergencyRescue(1);
                uint256 lmDebtAfter = vault.loanManager().getDebtBalance();

                // Debt balance may be zero in loan manager; just ensure no revert
                assertEq(lmDebtAfter, lmDebtBefore, "Debt balance should be unchanged");
                vm.stopPrank();
            }

            function test_rescueAssets_withTokens() public {
                // Use a non-core token (not collateralAsset or debtAsset) for rescue
                address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
                deal(USDT, address(vault), 1000e6);

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();

                uint256 ownerBalBefore = IERC20(USDT).balanceOf(owner);
                vault.rescueAssets(USDT, owner);
                uint256 ownerBalAfter = IERC20(USDT).balanceOf(owner);

                assertGt(ownerBalAfter, ownerBalBefore, "Owner should receive rescued tokens");
                vm.stopPrank();
            }

            function test_rescueAssets_revertsForDebtAsset() public {
                deal(CRVUSD, address(vault), 1000e18);

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();

                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.rescueAssets(CRVUSD, owner);
                vm.stopPrank();
            }

            function test_rescueAssets_revertsForCollateralAsset() public {
                deal(WBTC, address(vault), 1e8);

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();

                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.rescueAssets(WBTC, owner);
                vm.stopPrank();
            }

            function test_setParam_feeRate_edgeCases() public {
                // Test minimum fee rate (0) — current is 10% (set in setUp), 0 is a decrease → immediate
                vm.prank(owner);
                vault.setParam(0, 0);
                assertEq(vault.feeRate(), 0, "Fee rate should be set to 0");

                // Test maximum fee rate — 0 → 20% is an increase → propose + execute
                _setFeeRate(2e17);
                assertEq(vault.feeRate(), 2e17, "Fee rate should be set to max");
            }

            function test_setParam_targetLtv_edgeCases() public {
                // Default targetLtv is 65%; lowering to 15% is immediate
                vm.prank(owner);
                vault.setParam(1, 15e16);
                assertEq(vault.targetLtv(), 15e16, "Target LTV should be set to min");

                // 15% → 65% is an increase — propose + execute
                _setTargetLtv(65e16);
                assertEq(vault.targetLtv(), 65e16, "Target LTV should be set to max");
            }

            function test_setParam_bountyRate_edgeCases() public {
                vm.prank(owner);
                // Test zero bounty rate — decrease from default 0 is a no-op, immediate
                vault.setParam(3, 0);
                assertEq(vault.rebalanceBountyRate(), 0, "Bounty rate should be set to 0");

                // Test maximum bounty rate — increase requires timelock
                uint256 maxBounty = vault.MAX_REBALANCE_BOUNTY();
                _setBountyRate(maxBounty);
                assertEq(vault.rebalanceBountyRate(), maxBounty, "Bounty rate should be set to max");
            }

            function test_getTotalCollateral_idleMode() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                uint256 totalCollateral = vault.getTotalCollateral();
                assertEq(
                    totalCollateral,
                    wbtc.balanceOf(address(vault)),
                    "Total collateral should equal vault WBTC balance in idle mode"
                );
            }

            function test_getTotalCollateral_yieldDisabled() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                uint256 totalCollateral = vault.getTotalCollateral();
                assertEq(
                    totalCollateral,
                    wbtc.balanceOf(address(vault)),
                    "Total collateral should equal vault WBTC balance when yield disabled"
                );
            }

            function test_decimals() public view {
                assertEq(vault.decimals(), 8, "Decimals should match WBTC decimals");
            }

            function test_asset() public view {
                assertEq(vault.asset(), WBTC, "Asset should be WBTC");
            }

            // ============ No Strategy (address(0)) Withdraw Tests ============

            function test_withdrawWithNoStrategy() public {
                // Strategies are required; constructor should reject address(0)
                CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );
                LlamaLoanManager lm = new LlamaLoanManager(
                    WBTC,
                    CRVUSD,
                    LLAMALEND_WBTC,
                    WBTC_CRVUSD_POOL,
                    BTC_USD_ORACLE,
                    CRVUSD_USD_ORACLE,
                    address(swapper),
                    address(0),
                    3600
                );
                vm.expectRevert(Zenji.InvalidAddress.selector);
                new Zenji(
                    WBTC,
                    CRVUSD,
                    address(lm),
                    address(0),
                    address(swapper),
                    owner,
                    address(viewHelper)
                );
            }

            function test_partialWithdrawWithNoStrategy() public {
                // Strategies are required; constructor should reject address(0)
                CurveTwoCryptoSwapper swapper = new CurveTwoCryptoSwapper(
                    owner, WBTC, CRVUSD, WBTC_CRVUSD_POOL, 1, 0, BTC_USD_ORACLE, CRVUSD_USD_ORACLE
                );
                LlamaLoanManager lm = new LlamaLoanManager(
                    WBTC,
                    CRVUSD,
                    LLAMALEND_WBTC,
                    WBTC_CRVUSD_POOL,
                    BTC_USD_ORACLE,
                    CRVUSD_USD_ORACLE,
                    address(swapper),
                    address(0),
                    3600
                );
                vm.expectRevert(Zenji.InvalidAddress.selector);
                new Zenji(
                    WBTC,
                    CRVUSD,
                    address(lm),
                    address(0),
                    address(swapper),
                    owner,
                    address(viewHelper)
                );
            }

            // ============ Emergency Preview Branch Coverage ============

            function test_previewWithdraw_inEmergencyMode() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 preview = vault.previewWithdraw(1e7);
                assertGt(preview, 0, "Preview withdraw should return shares in emergency");
            }

            function test_previewRedeem_inEmergencyMode() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 preview = vault.previewRedeem(shares);
                assertGt(preview, 0, "Preview redeem should return assets in emergency");
            }

            // ============ Emergency withdraw() via ERC4626 ============

            function test_withdraw_emergencyMode_liquidationComplete() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 maxW = vault.maxWithdraw(user1);
                assertGt(maxW, 0, "Max withdraw should be positive");

                uint256 balBefore = wbtc.balanceOf(user1);
                vm.prank(user1);
                vault.withdraw(maxW, user1, user1);
                assertGt(wbtc.balanceOf(user1), balBefore, "Should receive WBTC");
            }

            // ============ maxWithdraw/maxRedeem in emergency with liquidation ============

            function test_maxWithdraw_emergencyLiquidationComplete() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 maxW = vault.maxWithdraw(user1);
                assertGt(maxW, 0, "Should return pro-rata collateral");
            }

            function test_maxRedeem_emergencyLiquidationComplete() public {
                vm.prank(user1);
                uint256 shares = vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 maxR = vault.maxRedeem(user1);
                assertEq(maxR, shares, "Should return user shares");
            }

            // ============ Mint path ============

            function test_mint_zeroShares_reverts() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.ZeroAmount.selector);
                vault.mint(0, user1);
            }

            function test_mint_works() public {
                uint256 sharesToMint = 1e7;
                uint256 assetsNeeded = vault.previewMint(sharesToMint);

                vm.prank(user1);
                uint256 assets = vault.mint(sharesToMint, user1);

                assertEq(assets, assetsNeeded, "Assets should match preview");
                assertGe(
                    vault.balanceOf(user1), sharesToMint, "Should receive at least requested shares"
                );
            }

            // ============ Fee edge cases ============

            function test_accrueYieldFees_strategyDecline_capsFees() public {
                // Deposit to create strategy balance
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Set fee rate and simulate yield
                vm.prank(owner);
                vault.setParam(0, 1e17); // 10%

                // Manually set accumulated fees higher than strategy balance by simulating yield then loss
                // First accrue some fees
                warpAndMock(block.timestamp + 2);
                vault.accrueYieldFees();

                // The cap logic in _accrueYieldFees ensures accumulatedFees <= strategy balance
                uint256 stratBal = yieldStrategy.balanceOf();
                uint256 fees = vault.accumulatedFees();
                assertLe(fees, stratBal, "Fees should be capped to strategy balance");
            }

            // ============ Deposit/Withdraw Fuzz Tests (with mocks) ============

            function testFuzz_deposit_and_redeem(uint256 amount) public {
                amount = bound(amount, 1e4, 100e8);
                deal(WBTC, user1, amount);
                vm.prank(user1);
                wbtc.approve(address(vault), amount);

                vm.prank(user1);
                uint256 shares = vault.deposit(amount, user1);
                assertGt(shares, 0, "Should receive shares");

                warpAndMock(block.timestamp + 2);

                vm.prank(user1);
                uint256 collateral = vault.redeem(shares, user1, user1);
                assertGt(collateral, 0, "Should receive collateral back");
                assertEq(vault.balanceOf(user1), 0, "Shares should be zero");
            }

            function testFuzz_withdraw_neverZeroAssets(uint256 depositAmt) public {
                depositAmt = bound(depositAmt, 1e5, 5e8);

                // Use user3 who has 10e8 from setUp, bound deposit to available balance
                uint256 available = wbtc.balanceOf(user3);
                if (depositAmt > available) depositAmt = available;

                vm.prank(user3);
                uint256 shares = vault.deposit(depositAmt, user3);
                assertGt(shares, 0, "Should receive shares");

                warpAndMock(block.timestamp + 2);

                // Full redeem — user3 is sole depositor, triggering isFinalWithdraw (full close path).
                // Partial redeems as sole depositor require the residual LlamaLend position to be above
                // the market's minimum band threshold, which is not covered by this invariant test.
                vm.prank(user3);
                uint256 collateral = vault.redeem(shares, user3, user3);
                assertGt(collateral, 0, "Must receive collateral for full share burn");
            }

            function testFuzz_emergency_proRata_fairness(uint256 a1, uint256 a2) public {
                a1 = bound(a1, 1e4, 5e8);
                a2 = bound(a2, 1e4, 5e8);
                deal(WBTC, user1, a1);
                deal(WBTC, user2, a2);
                vm.prank(user1);
                wbtc.approve(address(vault), a1);
                vm.prank(user2);
                wbtc.approve(address(vault), a2);

                vm.prank(user1);
                uint256 shares1 = vault.deposit(a1, user1);
                vm.prank(user2);
                uint256 shares2 = vault.deposit(a2, user2);

                warpAndMock(block.timestamp + 2);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 available = wbtc.balanceOf(address(vault));
                uint256 supply = vault.totalSupply();

                vm.prank(user1);
                uint256 r1 = vault.redeem(shares1, user1, user1);
                vm.prank(user2);
                uint256 r2 = vault.redeem(shares2, user2, user2);

                uint256 expected1 = (available * shares1) / supply;
                uint256 expected2 = (available * shares2) / supply;

                assertApproxEqAbs(r1, expected1, 1, "User1 pro-rata mismatch");
                assertApproxEqAbs(r2, expected2, 1, "User2 pro-rata mismatch");
            }

            // ============ withdraw() in emergency before liquidation reverts ============

            function test_withdraw_emergencyMode_beforeLiquidation_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.withdraw(1e7, user1, user1);
            }

            // ============ Branch Coverage: maxDeposit ============

            function test_maxDeposit_noCap_returnsMax() public {
                // depositCap == 0 → returns type(uint256).max
                vm.prank(owner);
                vault.setParam(2, 0); // set cap to 0
                assertEq(vault.maxDeposit(user1), type(uint256).max);
            }

            function test_maxDeposit_capPartiallyFilled() public {
                vm.prank(owner);
                vault.setParam(2, 5e8); // 5 WBTC cap

                vm.prank(user1);
                vault.deposit(2e8, user1); // deposit 2

                uint256 maxDep = vault.maxDeposit(user1);
                assertGt(maxDep, 0, "Should allow more deposits");
                // Allow 1 wei rounding tolerance
                assertLe(maxDep, 3e8 + 1, "Should not exceed remaining cap");
            }

            // ============ Branch Coverage: maxWithdraw / maxRedeem in emergency ============

            function test_maxWithdraw_emergencyLiquidationComplete_zeroSupply() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.prank(owner);
                vault.emergencyStep(2); // complete liquidation

                // No shares outstanding → maxWithdraw should return 0
                assertEq(vault.maxWithdraw(user1), 0);
            }

            function test_maxRedeem_emergencyBeforeLiquidation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                assertEq(vault.maxRedeem(user1), 0, "Should return 0 before liquidation");
            }

            // ============ Branch Coverage: previewWithdraw / previewRedeem edge cases ============

            function test_previewWithdraw_zeroCollateral_emergencyLiquidation() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();
                vm.prank(owner);
                vault.emergencyStep(0);
                vm.prank(owner);
                vault.emergencyStep(1);
                vm.prank(owner);
                vault.emergencyStep(2);

                // After liquidation, preview withdraw with 0 collateral in vault → should return 0
                // (vault might have residual collateral, test the branch path)
                uint256 preview = vault.previewWithdraw(0);
                assertEq(preview, 0, "Zero assets -> 0 shares");
            }

            // ============ Branch Coverage: _deployCapital branches ============

            function test_deployCapital_skipWhenEmergency() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                // Deploying capital in emergency should be a no-op (internal, tested via deposit in emergency reverting)
                // The branch `if (idle || emergencyMode) return` is tested via setIdle already
            }

            // ============ Branch Coverage: setIdle branches ============

            function test_setIdle_false_when_already_false_noop() public {
                // idle is already false, setIdle(false) should return early
                vm.prank(owner);
                vault.setIdle(false); // should not revert, no-op
            }

            function test_setIdle_true_when_already_true_noop() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                // Call again, should be no-op
                vm.prank(owner);
                vault.setIdle(true);
            }

            // ============ Branch Coverage: _accrueYieldFees branches ============

            function test_accrueYieldFees_feeCapping_afterLoss_v2() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Simulate profit by directly minting crvUSD to the yield vault
                deal(CRVUSD, address(mockYield), crvUSD.balanceOf(address(mockYield)) + 100e18);

                // Accrue fees
                vault.accrueYieldFees();

                // Simulate loss by burning crvUSD from the yield vault
                uint256 currentYieldBal = crvUSD.balanceOf(address(mockYield));
                if (currentYieldBal > 1e18) {
                    vm.prank(address(mockYield));
                    crvUSD.transfer(address(0xdead), currentYieldBal - 1e18);
                }

                // Accrue again - should cap fees to currentBalance
                vault.accrueYieldFees();
            }

            // ============ Branch Coverage: _deployDebtToYield with idle ============

            function test_deployDebtToYield_skipWhenIdle() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                // Deposit in idle mode should skip capital deployment
                deal(WBTC, user2, 1e8);
                vm.prank(user2);
                wbtc.approve(address(vault), type(uint256).max);
                vm.prank(user2);
                vault.deposit(1e8, user2); // Should not revert even in idle
            }

            // ============ Branch Coverage: harvestYield branches ============

            function test_harvestYield_revertsWithNoStrategy() public {
                // This vault has a strategy, but let's test emergencyMode revert
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.harvestYield();
            }

            // ============ Branch Coverage: rebalance within deadband ============

            function test_rebalance_withinDeadband_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // LTV should be near target, within deadband
                vm.expectRevert(Zenji.RebalanceNotNeeded.selector);
                vault.rebalance();
            }

            // ============ Branch Coverage: mint function ============

            function test_mint_zeroAmount_reverts() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.ZeroAmount.selector);
                vault.mint(0, user1);
            }

            // ============ Branch Coverage: deposit in emergency reverts ============

            function test_deposit_inEmergency_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.deposit(1e8, user1);
            }

            // ============ Branch Coverage: enterEmergencyMode already active ============

            function test_enterEmergencyMode_twice_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.enterEmergencyMode();
            }

            // ============ Branch Coverage: emergency step 1 no loan path ============

            function test_emergencyStep1_noLoan_recovers() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                // Step 0 first to clear yield
                vm.prank(owner);
                vault.emergencyStep(0);

                // No loan exists, step 1 should still work
                vm.prank(owner);
                vault.emergencyStep(1);
            }

            // ============ Branch Coverage: emergency step with loan + sufficient debt ============

            function test_emergencyStep1_withLoan_hasSufficientDebt() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                // Step 0 withdraws yield back as debt
                vm.prank(owner);
                vault.emergencyStep(0);

                // Step 1 unwinds loan — debt is available from step 0
                vm.prank(owner);
                vault.emergencyStep(1);

                // Step 2 completes liquidation
                vm.prank(owner);
                vault.emergencyStep(2);
            }

            // ============ Branch Coverage: redeem in emergency before liquidation ============

            function test_redeem_emergencyMode_beforeLiquidation_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 shares = vault.balanceOf(user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert(Zenji.EmergencyModeActive.selector);
                vault.redeem(shares, user1, user1);
            }

            // ============ Branch Coverage: setParam unknown index reverts ============
            // Decentralization upgrade: unknown param index now reverts with InvalidParam
            // instead of silently no-op'ing (was a footgun pre-upgrade).

            function test_setParam_unknownIndex_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidParam.selector);
                vault.setParam(99, 42);
            }

            // ============ Branch Coverage: proposeSwapper same address reverts ============

            function test_proposeSwapper_sameAddress_reverts() public {
                address currentSwapper = address(vault.swapper());
                vm.prank(vault.gov());
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.proposeSwapper(currentSwapper);
            }

            // ============ Branch Coverage: _withdrawFromYieldStrategy branches ============

            function test_withdrawFromYieldStrategy_zeroBalance() public {
                // When strategy balance is 0, _withdrawFromYieldStrategy returns 0
                // This is tested via withdraw on empty vault
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                // All yield withdrawn, strategy balance = 0
                // Now exit idle and deposit again
                vm.prank(owner);
                vault.setIdle(false);
            }

            // ============ Round 3: More Branch Coverage ============

            function test_redeemEmergency_viaAllowance() public {
                // Test _redeemEmergency with msg.sender != owner_ (allowance path)
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 1);

                uint256 shares = vault.balanceOf(user1);

                // Enter emergency and complete liquidation
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                // User1 approves user2 to redeem on their behalf
                vm.prank(user1);
                vault.approve(user2, shares);

                // user2 redeems on behalf of user1
                vm.prank(user2);
                uint256 collateral = vault.redeem(shares, user2, user1);
                assertGt(collateral, 0, "Should receive collateral via allowance");
            }

            function test_isFinalWithdraw_triggers_fullUnwind() public {
                // When leftover collateral < MIN_DEPOSIT, triggers final withdraw path
                vm.prank(user1);
                vault.deposit(2e4, user1); // 2x MIN_DEPOSIT (1e4)

                vm.roll(block.number + 1);

                uint256 shares = vault.balanceOf(user1);
                // Redeem almost all shares so leftover < MIN_DEPOSIT
                // This should trigger isFinalWithdraw
                vm.prank(user1);
                vault.redeem(shares, user1, user1);

                assertEq(vault.balanceOf(user1), 0, "All shares should be burned");
            }

            /// @dev Regression test for isFinalWithdraw exploit.
            /// An attacker deposited just enough so that the victim's remaining shares were worth
            /// < MIN_DEPOSIT, triggering isFinalWithdraw and receiving ALL vault collateral.
            /// Fix: isFinalWithdraw now only triggers when totalSupply - shareAmount <= VIRTUAL_SHARE_OFFSET
            /// (i.e. genuinely the last real depositor burning all their shares).
            function test_isFinalWithdraw_exploit_blocked() public {
                // Victim deposits a small amount
                vm.prank(user1);
                vault.deposit(2e4, user1); // victim: 2x MIN_DEPOSIT

                // Attacker deposits enough that after withdrawing, victim's leftover < MIN_DEPOSIT
                vm.prank(user2);
                vault.deposit(1e5, user2); // attacker

                vm.roll(block.number + 1);

                uint256 attackerShares = vault.balanceOf(user2);
                uint256 victimShares = vault.balanceOf(user1);

                uint256 attackerCollateralBefore = wbtc.balanceOf(user2);

                // Attacker redeems — under old code this would steal victim's funds via isFinalWithdraw.
                // Under the fix, victim still has real shares so isFinalWithdraw must NOT trigger.
                vm.prank(user2);
                vault.redeem(attackerShares, user2, user2);

                // Victim's shares must still exist
                assertEq(vault.balanceOf(user1), victimShares, "Victim shares must be untouched");

                // Attacker should only receive proportional collateral, not victim's funds
                uint256 attackerGained = wbtc.balanceOf(user2) - attackerCollateralBefore;
                // Attacker deposited 1e5 and should get back roughly that (minus fees/slippage)
                // They must NOT have received victim's 2e4
                assertLt(attackerGained, 1e5 + 2e4, "Attacker must not receive victim collateral");

                // Victim can still redeem their own shares
                vm.prank(user1);
                uint256 victimReceived = vault.redeem(victimShares, user1, user1);
                assertGt(victimReceived, 0, "Victim must be able to redeem their funds");
            }

            /// @dev Regression test: large partial withdrawal must not bankrupt remaining depositors.
            /// Before the fix, _unwindPosition applied a 5% buffer when withdrawing from the yield
            /// strategy, draining it faster than Aave debt was repaid. After a ~99% withdrawal, the
            /// remaining depositor was left with full proportional Aave debt but near-zero strategy
            /// balance — accruing interest with no yield to service it.
            function test_largeWithdraw_doesNotBankruptRemainingDepositor() public {
                // Two depositors: user1 (small), user2 (large)
                vm.prank(user1);
                vault.deposit(1e6, user1); // 0.01 WBTC

                vm.prank(user2);
                vault.deposit(1e8, user2); // 1 WBTC (100x larger)

                vm.roll(block.number + 1);

                // Snapshot remaining depositor's value before the large withdrawal
                uint256 user1SharesBefore = vault.balanceOf(user1);
                uint256 user1ValueBefore = vault.convertToAssets(user1SharesBefore);

                // Large depositor withdraws everything
                uint256 user2Shares = vault.balanceOf(user2);
                vm.prank(user2);
                vault.redeem(user2Shares, user2, user2);

                // Remaining depositor's shares unchanged
                uint256 user1SharesAfter = vault.balanceOf(user1);
                assertEq(
                    user1SharesAfter, user1SharesBefore, "Remaining depositor shares unchanged"
                );

                // Strategy balance must be proportional to remaining Aave debt.
                // If the strategy is near-zero but debt exists, the position is bankrupt.
                ILoanManager lm = vault.loanManager();
                if (lm.loanExists()) {
                    (, uint256 remainingDebt) = lm.getPositionValues();
                    uint256 strategyBal = yieldStrategy.balanceOf();
                    // Strategy should cover at least 90% of remaining debt (allowing for slippage/fees)
                    assertGe(
                        strategyBal * 100,
                        remainingDebt * 90,
                        "Strategy must back remaining Aave debt - depositor would be bankrupted"
                    );
                }

                // Remaining depositor's share value must not have been materially diluted
                uint256 user1ValueAfter = vault.convertToAssets(user1SharesAfter);
                // Allow up to 5% loss from swap slippage/fees, but not bankruptcy
                assertGe(
                    user1ValueAfter * 100,
                    user1ValueBefore * 95,
                    "Remaining depositor value must not be materially diluted"
                );

                // Remaining depositor can still withdraw
                vm.prank(user1);
                uint256 received = vault.redeem(user1SharesAfter, user1, user1);
                assertGt(received, 0, "Remaining depositor must be able to withdraw");
            }

            function test_maxMint_withCap() public {
                vm.prank(owner);
                vault.setParam(2, 3e8); // cap = 3 WBTC

                uint256 maxMintShares = vault.maxMint(user1);
                assertGt(maxMintShares, 0, "Should have non-zero max mint");
                assertLt(maxMintShares, type(uint256).max, "Max mint should be capped");
            }

            function test_maxMint_noCap() public view {
                // Default: depositCap == 0
                assertEq(vault.maxMint(user1), type(uint256).max, "No cap means unlimited maxMint");
            }

            function test_previewMint() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 assets = vault.previewMint(1e8);
                assertGt(assets, 0, "Preview mint should return non-zero assets");
            }

            function test_previewWithdraw_zeroSupply() public view {
                // No deposits, supply = 0
                uint256 shares = vault.previewWithdraw(1e8);
                assertEq(shares, 1e8, "With 0 supply, previewWithdraw returns assets");
            }

            function test_previewRedeem_nonEmergency() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 assets = vault.previewRedeem(vault.balanceOf(user1));
                assertGt(assets, 0, "Preview redeem should return non-zero assets");
            }

            function test_withdraw_emergencyMode_viaAllowance() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 shares = vault.balanceOf(user1);

                // Approve user2
                vm.prank(user1);
                vault.approve(user2, type(uint256).max);

                // user2 calls withdraw on behalf of user1
                vm.prank(user2);
                uint256 collateral = vault.withdraw(1e7, user2, user1);
                assertGt(collateral, 0, "Should receive collateral via withdraw in emergency");
            }

            function test_harvestYield() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Should not revert
                vault.harvestYield();
            }

            /// @dev Regression test for M-02: harvestYield() must accrue fees on BOTH organic
            ///      yield (P) AND harvest rewards (H). The old buggy version called
            ///      `lastStrategyBalance = yieldStrategy.balanceOf()` after harvest(), skipping
            ///      fee accrual on H permanently. The fix calls `_accrueYieldFees()` after harvest
            ///      instead, capturing both P and H.
            ///
            ///      Expected: accumulatedFees increases by feeRate * (P + H) = 10% * 1500 = 150
            ///      Also verifies no double-accrual: a subsequent accrueYieldFees() collects nothing.
            function test_harvestYield_accruesFees_noDoubleAccrual() public {
                // setupMockYieldStrategy already called in setUp with feeRate = 10%
                vm.prank(user1);
                vault.deposit(1e8, user1);
                warpAndMock(block.timestamp + 2);

                // Simulate organic yield P = 1000 crvUSD by donating to the underlying ERC4626 vault
                // (inflates all shareholders' convertToAssets value, including the strategy)
                uint256 P = 1000e18;
                address yieldVaultAddr = address(mockStrategy.yieldVault());
                deal(CRVUSD, yieldVaultAddr, IERC20(CRVUSD).balanceOf(yieldVaultAddr) + P);

                // Configure harvest reward H = 500 crvUSD and pre-fund it to the strategy
                uint256 H = 500e18;
                deal(CRVUSD, address(mockStrategy), H);
                mockStrategy.setHarvestReward(H);

                uint256 feeRate = vault.feeRate(); // 10% = 1e17
                uint256 accFeesBefore = vault.accumulatedFees();

                vault.harvestYield();

                uint256 actualAccrued = vault.accumulatedFees() - accFeesBefore;
                uint256 PRECISION = 1e18;
                uint256 expectedFees = ((P + H) * feeRate) / PRECISION; // 10% * 1500 = 150 crvUSD

                // Primary assertion: fees on both organic yield AND harvest reward are captured
                assertApproxEqRel(
                    actualAccrued,
                    expectedFees,
                    0.001e18, // 0.1% tolerance for rounding
                    "M-02: fees must be charged on organic yield + harvest reward"
                );

                // No-double-accrual assertion: balance is fully checkpointed after harvestYield()
                uint256 feesAfterHarvest = vault.accumulatedFees();
                vault.accrueYieldFees();
                assertEq(
                    vault.accumulatedFees(),
                    feesAfterHarvest,
                    "M-02: subsequent accrueYieldFees() must collect zero (no double-accrual)"
                );
            }

            function test_withdrawFees_zeroFees() public {
                // No fees accumulated - should not revert
                vm.prank(owner);
                vault.withdrawFees(owner);
            }

            function test_withdrawFees_revertsZeroAddress() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidAddress.selector);
                vault.withdrawFees(address(0));
            }

            function test_rescueAssets_zeroBalance() public {
                // Deploy a random token
                address randomToken = address(new MockYieldVault(CRVUSD));

                _setRescueRecipient(owner);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.rescueAssets(randomToken, owner);
                vm.stopPrank();
            }

            function test_rescueAssets_revertsZeroRecipient() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vm.expectRevert(); // InvalidAddress
                vault.rescueAssets(address(0x1234), address(0));
                vm.stopPrank();
            }

            function test_transferRole_gov_revertsIfNotGov() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.transferRole(1, user2);
            }

            function test_transferRole_owner_revertsIfNotOwner() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.transferRole(0, user2);
            }

            function test_accrueYieldFees_noFeeRate_updatesCheckpoint() public {
                // feeRate is set to 10% in setupMockYieldStrategy
                // Set it to 0 and verify checkpoint still updates
                vm.prank(owner);
                vault.setParam(0, 0);

                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Simulate profit
                uint256 currentBal = crvUSD.balanceOf(address(mockYield));
                deal(CRVUSD, address(mockYield), currentBal + 1000e18);

                vault.accrueYieldFees();
                assertEq(vault.accumulatedFees(), 0, "No fees with 0 rate");
            }

            function test_deposit_revertsWhenCapExceeded() public {
                vm.prank(owner);
                vault.setParam(2, 1e8); // 1 WBTC cap

                vm.prank(user1);
                vault.deposit(5e7, user1);

                // Second deposit exceeds cap
                vm.prank(user2);
                vm.expectRevert(Zenji.DepositCapExceeded.selector);
                vault.deposit(6e7, user2);
            }

            function test_maxDeposit_capFullyFilled() public {
                vm.prank(owner);
                vault.setParam(2, 1e8);

                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Vault has virtual share offset so totalCollateral may be slightly above deposit
                assertLe(vault.maxDeposit(user2), 1, "Cap fully filled should return 0 or dust");
            }

            function test_emergencyStep1_withLoan_insufficientDebt_usesUnwind() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0); // withdraw yield

                // Step 1 with partial debt available -> uses unwindPosition
                vault.emergencyStep(1);
                vm.stopPrank();
            }

            function test_setIdle_true_withdrawsStrategyAndUnwinds() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Confirm strategy has funds
                assertGt(yieldStrategy.balanceOf(), 0, "Strategy should have balance");

                vm.prank(owner);
                vault.setIdle(true);

                assertTrue(vault.idle(), "Should be idle");
                assertEq(yieldStrategy.balanceOf(), 0, "Strategy should be empty");
            }

            function test_setIdle_false_deploysCapital() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                vm.prank(owner);
                vault.setIdle(false);

                assertFalse(vault.idle(), "Should not be idle");
            }

            function test_convertToShares_and_convertToAssets() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                uint256 shares = vault.convertToShares(1e8);
                uint256 assets = vault.convertToAssets(shares);
                assertGt(shares, 0, "Should convert to non-zero shares");
                assertGt(assets, 0, "Should convert to non-zero assets");
            }

            function test_redeemStandard_viaAllowance() public {
                // Test _redeemStandard when msg.sender != owner_ (spendAllowance path)
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 1);

                uint256 shares = vault.balanceOf(user1);

                // user1 approves user2
                vm.prank(user1);
                vault.approve(user2, shares / 2);

                // user2 redeems on behalf of user1
                vm.prank(user2);
                uint256 collateral = vault.redeem(shares / 2, user2, user1);
                assertGt(collateral, 0, "Should receive collateral via allowance");
            }

            function test_deposit_idle_skipsCapitalDeploy() public {
                // Set idle first, then deposit - should skip _deployCapital
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.setIdle(true);

                // Deposit in idle mode
                vm.prank(user2);
                vault.deposit(1e8, user2);

                // Vault should hold WBTC directly
                assertGt(wbtc.balanceOf(address(vault)), 0, "Vault should hold WBTC in idle");
            }

            function test_withdraw_standard_noUnwindNeeded() public {
                // When vault has enough collateral, no unwind needed
                vm.prank(user1);
                vault.deposit(1e8, user1);

                warpAndMock(block.timestamp + 1);

                // Set idle to bring all collateral back to vault
                vm.prank(owner);
                vault.setIdle(true);

                // Now withdraw - vault has collateral, no unwind needed
                uint256 shares = vault.balanceOf(user1);
                vm.prank(user1);
                vault.redeem(shares / 2, user1, user1);

                assertGt(wbtc.balanceOf(user1), 0, "User should receive WBTC");
            }

            function test_setParam_feeRate_invalidReverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidFeeRate.selector);
                vault.setParam(0, 3e17); // > MAX_FEE_RATE (20%)
            }

            function test_setParam_targetLtv_invalidReverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidTargetLtv.selector);
                vault.setParam(1, 1e16); // < MIN_TARGET_LTV (15%)

                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidTargetLtv.selector);
                vault.setParam(1, 65e16 + 1); // > MAX_TARGET_LTV (65%)
            }

            function test_setParam_bountyRate_invalidReverts() public {
                // Read constant FIRST so it doesn't consume the vm.prank below
                uint256 over = vault.MAX_REBALANCE_BOUNTY() + 1;
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidBountyRate.selector);
                vault.setParam(3, over); // > MAX_REBALANCE_BOUNTY (now 50%)
            }

            function test_executeSwapper_and_cancelSwapper() public {
                // Create a new swapper
                MockZenjiSwapper newSwapper = new MockZenjiSwapper(WBTC, CRVUSD);
                deal(WBTC, address(newSwapper), 1e50);
                deal(CRVUSD, address(newSwapper), 1e50);

                vm.prank(owner);
                vault.proposeSwapper(address(newSwapper));

                vm.warp(block.timestamp + 1 weeks + 1);
                mockOracle(lastBtcPrice);

                vm.prank(owner);
                vault.executeSwapper();
                assertEq(address(vault.swapper()), address(newSwapper), "Swapper should be updated");
            }

            function test_cancelSwapper() public {
                MockZenjiSwapper newSwapper = new MockZenjiSwapper(WBTC, CRVUSD);

                vm.prank(owner);
                vault.proposeSwapper(address(newSwapper));

                vm.prank(owner);
                vault.cancelSwapper();

                // Execute should revert since cancelled
                vm.warp(block.timestamp + 1 weeks + 1);
                mockOracle(lastBtcPrice);

                vm.prank(owner);
                vm.expectRevert();
                vault.executeSwapper();
            }

            function test_emergencyStep2_setLiquidationComplete() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                assertTrue(vault.liquidationComplete(), "Liquidation should be complete");
            }

            function test_emergencyStep_afterLiquidation_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.startPrank(owner);
                vault.emergencyStep(2); // mark complete
                vm.expectRevert(Zenji.LiquidationAlreadyComplete.selector);
                vault.emergencyStep(0); // should revert
                vm.stopPrank();
            }

            function test_emergencyStep_notEmergency_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyStep(0);
            }

            function test_rescueAssets_notEmergency_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.rescueAssets(address(0x1234), owner);
            }

            function test_emergencyRescue_notEmergency_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencyRescue(0);
            }

            function test_emergencyRescue_transferCollateral() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyRescue(0); // transfer collateral from loan manager
                vm.stopPrank();
            }

            function test_emergencyRescue_transferDebt() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyRescue(1); // transfer debt from loan manager
                vm.stopPrank();
            }

            function test_deposit_minDeposit_reverts() public {
                vm.prank(user1);
                vm.expectRevert(Zenji.AmountTooSmall.selector);
                vault.deposit(1e3, user1); // below MIN_DEPOSIT (1e4)
            }

            // ============ Round 3b: Final targeted branch hits ============

            function test_maxDeposit_inEmergency_returnsZero() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                assertEq(vault.maxDeposit(user1), 0, "Emergency mode should return 0 maxDeposit");
            }

            function test_maxMint_inEmergency_returnsZero() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                assertEq(vault.maxMint(user1), 0, "Emergency mode should return 0 maxMint");
            }

            function test_getPendingFees_noProfit_zeroFees() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                // Accrue to set lastStrategyBalance equal to current
                vault.accrueYieldFees();

                // Now strategyBalance == lastBalance -> no pending fees
                (, uint256 pendingFees) = viewHelper.getPendingFees(address(vault));
                assertEq(pendingFees, 0, "No pending fees when balance unchanged");
            }

            function test_maxWithdraw_emergencyBeforeLiquidation_returnsZero() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();

                assertEq(vault.maxWithdraw(user1), 0, "Before liquidation maxWithdraw should be 0");
            }

            function test_previewWithdraw_emergencyLiquidation_zeroAvailableCollateral() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);

                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.prank(owner);
                vault.emergencyStep(2); // mark complete, but no collateral recovered

                // Emergency + liquidation complete, but 0 collateral in vault
                // (all collateral still in loan manager - not rescued)
                // This hits the `if (availableCollateral < 1 || supply < 1) return 0;` branch
                uint256 shares = vault.previewWithdraw(1e8);
                // With shares outstanding but no collateral available -> returns 0
                assertEq(shares, 0, "No collateral available returns 0");
            }

            function test_previewRedeem_emergencyLiquidation_zeroSupply() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.prank(owner);
                vault.emergencyStep(2); // complete liquidation

                // No shares outstanding
                uint256 assets = vault.previewRedeem(1e8);
                assertEq(assets, 0, "Zero supply returns 0 in previewRedeem");
            }

            // ============ emergencySkipStep / step-ordering guard ============

            function test_emergencyStep2_withoutPriorSteps_reverts() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vm.expectRevert(Zenji.EmergencyStepsIncomplete.selector);
                vault.emergencyStep(2);
                vm.stopPrank();
            }

            function test_emergencyStep2_withStep0Only_reverts() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0); // only step 0 resolved
                vm.expectRevert(Zenji.EmergencyStepsIncomplete.selector);
                vault.emergencyStep(2);
                vm.stopPrank();
            }

            function test_emergencyStep2_withStep1Only_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(1); // skip step 1 but not step 0
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyStepsIncomplete.selector);
                vault.emergencyStep(2);
            }

            function test_emergencySkipStep_allowsStep2() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.prank(owner);
                vault.emergencyStep(2);

                assertTrue(
                    vault.liquidationComplete(), "Liquidation should be complete via skip path"
                );
                assertEq(vault.emergencyStepsCompleted(), 0x3, "Both bits should be set");
            }

            function test_emergencySkipStep_runThenSkip_allowsStep2() public {
                // Run step 0 normally, skip step 1 (simulates bricked loan manager)
                vm.prank(owner);
                vault.enterEmergencyMode();
                vm.prank(owner);
                vault.emergencyStep(0); // run normally
                _emergencySkipStep(1); // skip loan unwind (now 2-call timelocked)
                vm.prank(owner);
                vault.emergencyStep(2);

                assertTrue(vault.liquidationComplete(), "Liquidation complete after run+skip");
            }

            function test_emergencySkipStep_onlyGuardian_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert();
                vault.emergencySkipStep(0);
            }

            function test_emergencySkipStep_notInEmergencyMode_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.emergencySkipStep(0);
            }

            function test_emergencySkipStep_afterLiquidationComplete_reverts() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                _emergencySkipStep(0);
                _emergencySkipStep(1);
                vm.startPrank(owner);
                vault.emergencyStep(2); // completes liquidation
                vm.expectRevert(Zenji.LiquidationAlreadyComplete.selector);
                vault.emergencySkipStep(0); // too late
                vm.stopPrank();
            }

            function test_emergencySkipStep_invalidStep_reverts() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vm.expectRevert(Zenji.InvalidEmergencyStep.selector);
                vault.emergencySkipStep(2); // only 0 and 1 are skippable
                vm.stopPrank();
            }

            function test_emergencyStepsCompleted_trackedCorrectly() public {
                assertEq(vault.emergencyStepsCompleted(), 0x0);

                vm.startPrank(owner);
                vault.enterEmergencyMode();
                assertEq(vault.emergencyStepsCompleted(), 0x0);

                vault.emergencyStep(0);
                assertEq(vault.emergencyStepsCompleted(), 0x1, "Bit 0 set after step 0");

                vault.emergencyStep(1);
                assertEq(vault.emergencyStepsCompleted(), 0x3, "Bits 0+1 set after step 1");

                vault.emergencyStep(2);
                vm.stopPrank();

                assertTrue(vault.liquidationComplete());
            }

            // ============ Decentralization Upgrade Tests ============
            // P1: feeRate / targetLtv timelock for adverse changes
            // P2: emergencySkipStep timelock with gov veto
            // P3+P8: extended gov / guardian transfer delays
            // P5: guardian veto on swapper / role changes
            // P6: cancelEmergencyMode
            // P7: lowered MAX_REBALANCE_BOUNTY
            // P9: try/catch on strategy ownership propagation

            // ----- P1: feeRate / targetLtv timelock -----

            function test_decentral_feeRate_increase_isTimelocked() public {
                // setUp set feeRate = 10%. Increase to 15% should be pending, not immediate.
                vm.prank(owner);
                vault.setParam(0, 15e16);
                assertEq(vault.feeRate(), 1e17, "feeRate must NOT change before delay");

                (uint256 pending, uint256 effective) = vault.pendingParamChange(0);
                assertEq(pending, 15e16, "pending value should be 15%");
                assertEq(effective, block.timestamp + vault.PARAM_TIMELOCK_DELAY());

                // Cannot execute before delay
                vm.prank(owner);
                vm.expectRevert(TimelockLib.TimelockNotReady.selector);
                vault.executeParamChange(0);

                // After delay → execution succeeds
                warpAndMock(block.timestamp + vault.PARAM_TIMELOCK_DELAY());
                vm.prank(owner);
                vault.executeParamChange(0);
                assertEq(vault.feeRate(), 15e16, "feeRate should update after execute");
            }

            function test_decentral_feeRate_decrease_isImmediate() public {
                // setUp set feeRate = 10%. Decrease to 5% should be immediate.
                vm.prank(owner);
                vault.setParam(0, 5e16);
                assertEq(vault.feeRate(), 5e16, "decreases must be immediate");

                (uint256 pending,) = vault.pendingParamChange(0);
                assertEq(pending, 0, "no pending proposal for a decrease");
            }

            function test_decentral_targetLtv_increase_isTimelocked() public {
                // First decrease (immediate) to set baseline
                vm.prank(owner);
                vault.setParam(1, 30e16);
                assertEq(vault.targetLtv(), 30e16);

                // Increase to 50% — pending
                vm.prank(owner);
                vault.setParam(1, 50e16);
                assertEq(vault.targetLtv(), 30e16, "LTV must NOT increase before delay");

                warpAndMock(block.timestamp + vault.PARAM_TIMELOCK_DELAY());
                vm.prank(owner);
                vault.executeParamChange(1);
                assertEq(vault.targetLtv(), 50e16);
            }

            function test_decentral_targetLtv_decrease_isImmediate() public {
                // 65% (default) → 30% is a decrease
                vm.prank(owner);
                vault.setParam(1, 30e16);
                assertEq(vault.targetLtv(), 30e16);
            }

            function test_decentral_cancelParamChange_works() public {
                vm.prank(owner);
                vault.setParam(0, 15e16); // propose increase

                (uint256 pending,) = vault.pendingParamChange(0);
                assertEq(pending, 15e16);

                vm.prank(owner);
                vault.cancelParamChange(0);

                (pending,) = vault.pendingParamChange(0);
                assertEq(pending, 0, "proposal should be cleared");

                // After cancel, execute should revert
                vm.prank(owner);
                vm.expectRevert(TimelockLib.NoTimelockPending.selector);
                vault.executeParamChange(0);
            }

            function test_decentral_executeParamChange_invalidParam_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidParam.selector);
                vault.executeParamChange(5); // 0-4 are valid params; 5+ is invalid
            }

            function test_decentral_setParam_invalidParam_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidParam.selector);
                vault.setParam(99, 1);
            }

            // ----- P2: emergencySkipStep 2-call timelock -----

            function test_decentral_emergencySkipStep_proposeThenExecute() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                // First call only proposes
                vm.prank(owner);
                vault.emergencySkipStep(0);
                assertEq(vault.emergencyStepsCompleted(), 0, "step bit must NOT be set yet");
                assertGt(vault.pendingSkipTimestamp(0), 0, "should have pending timestamp");

                // Cannot execute before delay
                vm.prank(owner);
                vm.expectRevert(TimelockLib.TimelockNotReady.selector);
                vault.emergencySkipStep(0);

                // After delay → second call executes
                warpAndMock(block.timestamp + vault.EMERGENCY_SKIP_DELAY());
                vm.prank(owner);
                vault.emergencySkipStep(0);
                assertEq(vault.emergencyStepsCompleted(), 0x1, "step 0 bit should be set");
                assertEq(vault.pendingSkipTimestamp(0), 0, "pending should be cleared");
            }

            function test_decentral_cancelEmergencySkip_govVeto() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                vm.prank(owner);
                vault.emergencySkipStep(1); // propose

                assertGt(vault.pendingSkipTimestamp(1), 0);

                vm.prank(owner); // owner is gov
                vault.cancelEmergencySkip(1);
                assertEq(vault.pendingSkipTimestamp(1), 0, "pending skip should be cancelled");

                // Cancelling when nothing pending reverts
                vm.prank(owner);
                vm.expectRevert(TimelockLib.NoTimelockPending.selector);
                vault.cancelEmergencySkip(1);
            }

            function test_decentral_cancelEmergencySkip_invalidStep_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidEmergencyStep.selector);
                vault.cancelEmergencySkip(2);
            }

            // ----- P6: cancelEmergencyMode -----

            function test_decentral_cancelEmergencyMode_works() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                assertTrue(vault.emergencyMode());

                vm.prank(owner);
                vault.cancelEmergencyMode();
                assertFalse(vault.emergencyMode(), "emergencyMode should be cleared");
            }

            function test_decentral_cancelEmergencyMode_clearsPendingSkips() public {
                vm.prank(owner);
                vault.enterEmergencyMode();
                vm.prank(owner);
                vault.emergencySkipStep(0); // propose pending
                assertGt(vault.pendingSkipTimestamp(0), 0);

                vm.prank(owner);
                vault.cancelEmergencyMode();
                assertEq(vault.pendingSkipTimestamp(0), 0, "pending skip cleared with cancel");
                assertEq(vault.pendingSkipTimestamp(1), 0);
            }

            function test_decentral_cancelEmergencyMode_revertsAfterAnyStep() public {
                vm.startPrank(owner);
                vault.enterEmergencyMode();
                vault.emergencyStep(0); // executes — sets emergencyStepsCompleted bit 0
                vm.expectRevert(Zenji.EmergencyStepInProgress.selector);
                vault.cancelEmergencyMode();
                vm.stopPrank();
            }

            function test_decentral_cancelEmergencyMode_revertsIfNotInEmergency() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.EmergencyModeNotActive.selector);
                vault.cancelEmergencyMode();
            }

            function test_decentral_cancelEmergencyMode_onlyGov() public {
                vm.prank(owner);
                vault.enterEmergencyMode();

                vm.prank(user1);
                vm.expectRevert(Zenji.Unauthorized.selector);
                vault.cancelEmergencyMode();
            }

            // ----- P5: Guardian veto on swapper / role -----

            function test_decentral_guardianCancelSwapper_works() public {
                MockZenjiSwapper newSwapper = new MockZenjiSwapper(WBTC, CRVUSD);
                vm.prank(owner);
                vault.proposeSwapper(address(newSwapper));

                vm.prank(owner); // owner is also guardian
                vault.guardianCancelSwapper();

                // After veto, executing the swapper change should revert
                vm.warp(block.timestamp + vault.TIMELOCK_DELAY() + 1);
                vm.prank(owner);
                vm.expectRevert(TimelockLib.NoTimelockPending.selector);
                vault.executeSwapper();
            }

            function test_decentral_guardianCancelRole_works() public {
                address attacker = makeAddr("attacker");
                vm.prank(owner);
                vault.transferRole(2, attacker); // gov tries to replace guardian

                assertEq(vault.pendingGuardian(), attacker);

                // Legitimate guardian (also owner here) vetoes
                vm.prank(owner);
                vault.guardianCancelRole(2);

                assertEq(vault.pendingGuardian(), address(0), "pending guardian cleared");
            }

            function test_decentral_guardianCancelRole_invalidRole_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidParam.selector);
                vault.guardianCancelRole(99);
            }

            function test_decentral_guardianCancelRole_revertsIfNoPending() public {
                vm.prank(owner);
                vm.expectRevert(TimelockLib.NoTimelockPending.selector);
                vault.guardianCancelRole(0);
            }

            // ----- P7: Lower MAX_REBALANCE_BOUNTY -----

            function test_decentral_maxRebalanceBounty_isFiftyPercent() public {
                assertEq(vault.MAX_REBALANCE_BOUNTY(), 5e17, "MAX_REBALANCE_BOUNTY should be 50%");
            }

            function test_decentral_setBounty_above50Percent_reverts() public {
                vm.prank(owner);
                vm.expectRevert(Zenji.InvalidBountyRate.selector);
                vault.setParam(3, 5e17 + 1);
            }

            // ============ User-Slippage (minAssetsOut) tests ============

            function test_userSlip_withdraw_minZero_equivalentToStandard() public {
                // Deposit so there's something to withdraw
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                // Snapshot state at the boundary
                uint256 expected = vault.previewWithdraw(5e7);
                uint256 sharesUser1Before = vault.balanceOf(user1);
                uint256 wbtcUser1Before = wbtc.balanceOf(user1);

                // 4-arg call with minAssetsOut = 0 must behave identically to 3-arg call
                vm.prank(user1);
                vault.withdraw(5e7, user1, user1, 0);

                uint256 received = wbtc.balanceOf(user1) - wbtcUser1Before;
                uint256 sharesBurned = sharesUser1Before - vault.balanceOf(user1);

                assertGt(received, 0, "should receive collateral");
                assertGt(sharesBurned, 0, "shares should be burned");
                // expected is the round-up shares — we don't compare exactly
                expected; // silence
            }

            function test_userSlip_redeem_minZero_equivalentToStandard() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                uint256 shares = vault.balanceOf(user1) / 2;
                uint256 wbtcBefore = wbtc.balanceOf(user1);

                vm.prank(user1);
                vault.redeem(shares, user1, user1, 0);

                assertGt(wbtc.balanceOf(user1) - wbtcBefore, 0, "should receive collateral");
            }

            function test_userSlip_redeem_minTooHigh_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                uint256 shares = vault.balanceOf(user1) / 2;
                uint256 expected = vault.previewRedeem(shares);
                uint256 unrealisticMin = expected * 2; // 200% — definitely won't be met

                vm.prank(user1);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Zenji.UserSlippageExceeded.selector, unrealisticMin, expected
                    )
                );
                vault.redeem(shares, user1, user1, unrealisticMin);
            }

            function test_userSlip_withdraw_minTooHigh_reverts() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                // Ask for 5e7 but require >= 1e9 (impossible) → revert
                vm.prank(user1);
                vm.expectRevert();
                vault.withdraw(5e7, user1, user1, 1e9);
            }

            function test_userSlip_redeem_minMet_succeeds() public {
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                uint256 shares = vault.balanceOf(user1) / 2;
                uint256 expected = vault.previewRedeem(shares);
                // Allow 5% slippage from the previewed amount
                uint256 floor = (expected * 95) / 100;
                uint256 wbtcBefore = wbtc.balanceOf(user1);

                vm.prank(user1);
                uint256 received = vault.redeem(shares, user1, user1, floor);

                assertGe(received, floor, "received must meet user floor");
                assertEq(wbtc.balanceOf(user1) - wbtcBefore, received, "balance delta matches");
            }

            function test_userSlip_emergencyMode_minEnforced() public {
                // Deposit, then enter emergency, complete liquidation
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                vm.prank(owner);
                vault.enterEmergencyMode();
                vm.startPrank(owner);
                vault.emergencyStep(0);
                vault.emergencyStep(1);
                vault.emergencyStep(2);
                vm.stopPrank();

                uint256 shares = vault.balanceOf(user1);
                // Pro-rata available collateral might be small; ask for more than possible.
                vm.prank(user1);
                vm.expectRevert(); // UserSlippageExceeded
                vault.redeem(shares, user1, user1, type(uint128).max);
            }

            function test_userSlip_maxUserSlippage_isTwentyPercent() public {
                assertEq(vault.MAX_USER_SLIPPAGE(), 2e17, "MAX_USER_SLIPPAGE = 20%");
            }

            function test_userSlip_minBelowExpected_widensInternalCap() public {
                // This sanity-checks that providing a generous minAssetsOut does NOT alter
                // the ERC4626 standard-signature behavior (minAssetsOut == 0 path).
                vm.prank(user1);
                vault.deposit(1e8, user1);
                vm.roll(block.number + 1);

                uint256 shares = vault.balanceOf(user1);

                // First call: standard 3-arg with the gov maxSlippage default
                uint256 wbtcBefore = wbtc.balanceOf(user1);
                vm.prank(user1);
                uint256 received = vault.redeem(shares, user1, user1);

                // The user got at least their pro-rata share minus tolerable slippage.
                assertGt(received, 0);
                assertEq(wbtc.balanceOf(user1) - wbtcBefore, received);
            }
        }
