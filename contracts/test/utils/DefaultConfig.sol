// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Config, PortalTypeParams} from "../../src/PortalLabTypes.sol";
import {GameConfig} from "../../src/GameConfig.sol";

/// @title DefaultConfig — thin test wrapper over the canonical deployment values.
/// @notice The actual numbers live in src/GameConfig.sol. Edit them there, not here.
/// This file exists only so test files can `import {DefaultConfig}` without changes.
library DefaultConfig {
    function config() internal pure returns (Config memory) {
        return GameConfig.config();
    }

    function portalTypeParams() internal pure returns (PortalTypeParams[5] memory) {
        return GameConfig.portalTypeParams();
    }
}
