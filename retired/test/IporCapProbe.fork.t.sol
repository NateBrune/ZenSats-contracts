// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test, console } from "forge-std/Test.sol";

interface IPlasma {
    function maxDeposit(address) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
}

interface IERC20D {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

contract IporCapProbe is Test {
    address constant IPOR = 0xbfA9d6EC0E04B6691fCAE5F8b48838C3918eC117;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ETH_RPC_URL", string(""));
        vm.createSelectFork(rpc);
    }

    function test_probe_iporCap() public view {
        IPlasma v = IPlasma(IPOR);
        address asset = v.asset();
        uint8 dec = IERC20D(asset).decimals();
        uint256 ta = v.totalAssets();
        uint256 md = v.maxDeposit(address(this));

        console.log("block:", block.number);
        console.log("IPOR PlasmaVault:", IPOR);
        console.log("underlying asset:", asset, IERC20D(asset).symbol());
        console.log("decimals:", dec);
        console.log("totalAssets (raw):", ta);
        console.log("totalAssets (units):", ta / (10 ** dec));
        console.log("maxDeposit now (raw):", md);
        console.log("maxDeposit now (units):", md / (10 ** dec));
        // Try the supply cap getter (IPOR Fusion PlasmaVaultGovernance), soft.
        (bool ok, bytes memory d) =
            IPOR.staticcall(abi.encodeWithSignature("getTotalSupplyCap()"));
        if (ok && d.length >= 32) {
            uint256 cap = abi.decode(d, (uint256));
            console.log("getTotalSupplyCap (raw):", cap);
            console.log("getTotalSupplyCap (units):", cap / (10 ** dec));
            console.log("headroom (units):", cap > ta ? (cap - ta) / (10 ** dec) : 0);
        } else {
            console.log("getTotalSupplyCap(): not exposed / reverted");
        }
    }
}
