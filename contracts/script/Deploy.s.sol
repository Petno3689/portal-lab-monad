// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {Config} from "../src/PortalLabTypes.sol";
import {PythEntropySource} from "../src/PythEntropySource.sol";

/// @notice Deployment script for PortalLab.
/// @dev Sign with the encrypted Foundry keystore only. Never pass a raw key:
/// no --private-key flag, no PRIVATE_KEY env var, never a key in this file.
///
/// Example (Monad testnet, run from contracts/; full procedure in docs/DEPLOY.md):
///   forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast \
///     --account portal-deployer
///
/// The script prints the deployed address and key configuration parameters so
/// the deploy log shows exactly what landed on chain.
contract DeployScript is Script {
    /// @dev Pyth Entropy V2 proxy on Monad testnet (SPEC §6.1). The PROXY, never
    /// the implementation — and NOT the dead address in the Monad oracle docs.
    address internal constant PYTH_ENTROPY = 0x825c0390f379C631f3Cf11A82a37D20BddF93c07;

    /// @dev Default entropy provider on Monad testnet (SPEC §6.1).
    address internal constant PYTH_PROVIDER = 0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344;

    function run() external {
        Config memory cfg = GameConfig.config();

        console.log("==========================================================");
        console.log("Randomness: Pyth Entropy V2 (two-phase actions, SPEC 6).");
        console.log("Survey, blind rescue and spawn draws are delivered by a");
        console.log("fulfillment callback and are NOT knowable before the");
        console.log("request transaction lands. Stuck requests can be cancelled");
        console.log("by the player after requestTimeoutHours, by anyone else");
        console.log("after outsiderTimeoutHours (cancelDeferred).");
        console.log("==========================================================");

        console.log("Deploying PortalLab with:");
        console.log("  hpStart        =", cfg.hpStart);
        console.log("  hpMax          =", cfg.hpMax);
        console.log("  secPerHour     =", cfg.secPerHour);
        console.log("  epochHours     =", cfg.epochHours);
        console.log("  requestTimeoutHours  =", cfg.requestTimeoutHours);
        console.log("  outsiderTimeoutHours =", cfg.outsiderTimeoutHours);

        vm.startBroadcast();
        // The randomness source is a separate contract (Ticket 4.4 §1.3): the only
        // place Pyth types live. Deploy it first, then point the game at it.
        PythEntropySource source = new PythEntropySource(PYTH_ENTROPY, PYTH_PROVIDER);
        PortalLab lab = new PortalLab(cfg, GameConfig.portalTypeParams(), source);
        vm.stopBroadcast();

        console.log("PythEntropySource deployed at:", address(source));
        console.log("PortalLab deployed at:", address(lab));
    }
}
