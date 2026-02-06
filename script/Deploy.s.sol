// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Script, console } from "forge-std/Script.sol";
import { Zenji } from "../src/Zenji.sol";
import { ZenjiViewHelper } from "../src/ZenjiViewHelper.sol";
import { VaultTracker } from "../src/VaultTracker.sol";
import { AaveLoanManager } from "../src/AaveLoanManager.sol";
import { LlamaLoanManager } from "../src/LlamaLoanManager.sol";
import { IporYieldStrategy } from "../src/strategies/IporYieldStrategy.sol";
import { TokemakYieldStrategy } from "../src/strategies/TokemakYieldStrategy.sol";
import { UsdtIporYieldStrategy } from "../src/strategies/UsdtIporYieldStrategy.sol";

/// @title Deploy
/// @notice Deployment script for SiloBooster contracts
contract Deploy is Script {
    // ============ Mainnet Addresses ============
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant LLAMALEND_CONTROLLER = 0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67;
    address constant WBTC_CRVUSD_POOL = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address constant BTC_USD_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant CRVUSD_USD_ORACLE = 0xEEf0C605546958c1f899b6fB336C20671f9cD49F;

    // Aave mainnet addresses (v3)
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_WBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_VAR_DEBT_USDT = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    // Yield venues
    address constant IPOR_PLASMA_VAULT = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;
    address constant TOKEMAK_AUTOPOOL = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address constant TOKEMAK_ROUTER = 0x39ff6d21204B919441d17bef61D19181870835A2;
    address constant TOKEMAK_REWARDER = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    address constant CURVE_CRVUSD_USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address constant SUSHI_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    // ============ Step 1: Deploy Vault ============

    /// @notice Deploy the vault without a strategy (strategy set later)
    function deployVault(address owner) external returns (address vault, address tracker) {
        vm.startBroadcast();

        uint64 nonce = vm.getNonce(msg.sender);
        address predictedVault = vm.computeCreateAddress(msg.sender, nonce + 2);

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            predictedVault
        );

        // Deploy vault with zero strategy
        Zenji siloVault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            address(0), // No strategy yet
            owner,
            address(viewHelper)
        );
        vault = address(siloVault);
        console.log("Zenji deployed at:", vault);

        // Deploy tracker
        VaultTracker vaultTracker = new VaultTracker(vault);
        tracker = address(vaultTracker);
        console.log("VaultTracker deployed at:", tracker);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Vault:", vault);
        console.log("Tracker:", tracker);
        console.log("Owner:", owner);
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy a strategy using deployIporStrategy or deployTokemakStrategy");
        console.log("2. Call vault.setInitialStrategy(strategyAddress)");
        console.log("3. Call vault.toggleYield(true) to enable yield deployment");
    }

    // ============ Step 2: Deploy Strategy ============

    /// @notice Deploy IPOR strategy for a vault
    function deployIporStrategy(address vault) external returns (address strategy) {
        vm.startBroadcast();

        IporYieldStrategy iporStrategy = new IporYieldStrategy(CRVUSD, vault, IPOR_PLASMA_VAULT);
        strategy = address(iporStrategy);

        vm.stopBroadcast();

        console.log("IporYieldStrategy deployed at:", strategy);
        console.log("For vault:", vault);
        console.log("");
        console.log("Next step: Call vault.setInitialStrategy(", strategy, ")");
    }

    /// @notice Deploy Tokemak strategy for a vault
    function deployTokemakStrategy(address vault) external returns (address strategy) {
        vm.startBroadcast();

        TokemakYieldStrategy tokemakStrategy = new TokemakYieldStrategy(
            CRVUSD,
            vault,
            USDC,
            CURVE_CRVUSD_USDC_POOL,
            TOKEMAK_AUTOPOOL,
            TOKEMAK_ROUTER,
            TOKEMAK_REWARDER,
            SUSHI_ROUTER
        );
        strategy = address(tokemakStrategy);

        vm.stopBroadcast();

        console.log("TokemakYieldStrategy deployed at:", strategy);
        console.log("For vault:", vault);
        console.log("");
        console.log("Next step: Call vault.setInitialStrategy(", strategy, ")");
    }

    // ============ Step 3: Set Strategy ============

    /// @notice Set the initial strategy on the vault
    function setInitialStrategy(address vault, address strategy) external {
        vm.startBroadcast();

        Zenji(vault).setInitialStrategy(strategy);

        vm.stopBroadcast();

        console.log("Strategy set on vault");
        console.log("Vault:", vault);
        console.log("Strategy:", strategy);
    }

    // ============ All-in-One Deployments ============

    /// @notice Deploy everything with IPOR strategy in one transaction
    function deployAllWithIpor(address owner)
        external
        returns (address vault, address strategy, address tracker)
    {
        vm.startBroadcast();

        // Step 1: Compute future vault address
        uint64 nonce = vm.getNonce(msg.sender);
        address predictedVault = vm.computeCreateAddress(msg.sender, nonce + 3);

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        // Step 2: Deploy strategy with predicted vault
        IporYieldStrategy iporStrategy =
            new IporYieldStrategy(CRVUSD, predictedVault, IPOR_PLASMA_VAULT);
        strategy = address(iporStrategy);

        // Step 3: Deploy loan manager with predicted vault address
        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            predictedVault
        );

        // Step 4: Deploy vault with strategy
        Zenji siloVault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            strategy,
            owner,
            address(viewHelper)
        );
        vault = address(siloVault);
        require(vault == predictedVault, "Vault address mismatch");

        // Step 5: Deploy tracker
        VaultTracker vaultTracker = new VaultTracker(vault);
        tracker = address(vaultTracker);

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Vault:", vault);
        console.log("Strategy (IPOR):", strategy);
        console.log("Tracker:", tracker);
        console.log("Owner:", owner);
    }

    /// @notice Deploy everything with Tokemak strategy in one transaction
    function deployAllWithTokemak(address owner)
        external
        returns (address vault, address strategy, address tracker)
    {
        vm.startBroadcast();

        // Step 1: Compute future vault address
        uint64 nonce = vm.getNonce(msg.sender);
        address predictedVault = vm.computeCreateAddress(msg.sender, nonce + 3);

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        // Step 2: Deploy strategy with predicted vault
        TokemakYieldStrategy tokemakStrategy = new TokemakYieldStrategy(
            CRVUSD,
            predictedVault,
            USDC,
            CURVE_CRVUSD_USDC_POOL,
            TOKEMAK_AUTOPOOL,
            TOKEMAK_ROUTER,
            TOKEMAK_REWARDER,
            SUSHI_ROUTER
        );
        strategy = address(tokemakStrategy);

        // Step 3: Deploy loan manager with predicted vault address
        LlamaLoanManager loanManager = new LlamaLoanManager(
            WBTC,
            CRVUSD,
            LLAMALEND_CONTROLLER,
            WBTC_CRVUSD_POOL,
            BTC_USD_ORACLE,
            CRVUSD_USD_ORACLE,
            predictedVault
        );

        // Step 4: Deploy vault with strategy
        Zenji siloVault = new Zenji(
            WBTC,
            CRVUSD,
            address(loanManager),
            strategy,
            owner,
            address(viewHelper)
        );
        vault = address(siloVault);
        require(vault == predictedVault, "Vault address mismatch");

        // Step 5: Deploy tracker
        VaultTracker vaultTracker = new VaultTracker(vault);
        tracker = address(vaultTracker);

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Vault:", vault);
        console.log("Strategy (Tokemak):", strategy);
        console.log("Tracker:", tracker);
        console.log("Owner:", owner);
    }

    // ============ Aave + USDT + IPOR Deployment ============

    /// @notice Deploy Zenji + AaveLoanManager + UsdtIporYieldStrategy + Tracker
    /// @dev Uses initializer-based vault wiring to avoid precomputed addresses.
    function deployAllWithAaveUsdtIpor(
        address owner,
        address curvePool,
        address iporVault,
        int128 usdtIndex,
        int128 crvUsdIndex,
        address swapper
    )
        external
        returns (address vault, address strategy, address tracker)
    {
        vm.startBroadcast();

        ZenjiViewHelper viewHelper = new ZenjiViewHelper();

        // 1) Deploy loan manager and strategy with vault unset (initializer = deployer)
        AaveLoanManager loanManager = new AaveLoanManager(
            WBTC,
            USDT,
            AAVE_A_WBTC,
            AAVE_VAR_DEBT_USDT,
            AAVE_POOL,
            BTC_USD_ORACLE,
            USDT_USD_ORACLE,
            swapper,
            7500,
            8000,
            address(0)
        );

        UsdtIporYieldStrategy usdtIporStrategy = new UsdtIporYieldStrategy(
            USDT,
            CRVUSD,
            address(0),
            curvePool,
            iporVault,
            usdtIndex,
            crvUsdIndex
        );
        strategy = address(usdtIporStrategy);

        // 2) Deploy vault pointing at loan manager + strategy
        Zenji siloVault = new Zenji(
            WBTC,
            USDT,
            address(loanManager),
            address(0),
            owner,
            address(viewHelper)
        );
        vault = address(siloVault);

        // 3) Initialize vault references
        loanManager.initializeVault(vault);
        usdtIporStrategy.initializeVault(vault);

        // 4) Ensure strategy is set and enable yield (owner-only)
        if (owner == msg.sender) {
            Zenji(vault).setInitialStrategy(strategy);
            Zenji(vault).toggleYield(true);
        }

        // 5) Deploy tracker
        VaultTracker vaultTracker = new VaultTracker(vault);
        tracker = address(vaultTracker);

        vm.stopBroadcast();

        console.log("=== Deployment Complete (Aave + USDT + IPOR) ===");
        console.log("Vault:", vault);
        console.log("LoanManager (Aave):", address(loanManager));
        console.log("Strategy (USDT/IPOR):", strategy);
        console.log("Tracker:", tracker);
        console.log("Owner:", owner);
        if (owner != msg.sender) {
            console.log("Next steps (run as owner):");
            console.log("- setInitialStrategy(", strategy, ")");
            console.log("- toggleYield(true)");
        }
    }
}
