// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NameRegistry} from "../src/NameRegistry.sol";

/// @notice Deployment script for NameRegistry.
/// @dev Sign with the encrypted Foundry keystore only; no key handling here.
///
/// Example (Monad testnet, run from contracts/):
///   forge script script/DeployNames.s.sol --rpc-url monad_testnet --broadcast --account portal-deployer
contract DeployNamesScript is Script {
    function run() external {
        vm.startBroadcast();
        NameRegistry registry = new NameRegistry();
        vm.stopBroadcast();

        console.log("NameRegistry deployed at:", address(registry));
    }
}
