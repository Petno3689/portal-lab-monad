// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Game, Portal, Config, PortalTypeParams, MAX_OPEN_PORTALS, MAX_CATCHUP_EVENTS
} from "../../src/PortalLabTypes.sol";
import {TimeLib} from "../../src/TimeLib.sol";

/// @title TimeHarness — external face of `TimeLib.catchUp`.
/// @notice `catchUp` is an internal pure library function, so a revert inside it
/// cannot be caught by its caller. Through this contract the call is EXTERNAL:
/// reverts become catchable (`try/catch`), which is the only way a vector can
/// record "this call reverts" — and, as a second benefit, the arguments are
/// ABI-copied, so the library's in-place mutation of its memory structs can never
/// leak back into the caller's inputs.
/// Used by the spawn vector generator and by the spawn golden test for the
/// refusal section; the non-reverting vectors call the library directly, as
/// CatchUpGolden does.
contract TimeHarness {
    function catchUp(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        PortalTypeParams[5] memory types,
        uint256 oldWord,
        uint256 newWord,
        uint32 storedCoveredEpochs,
        uint32 maxCoveredEpochs,
        uint40 nowTs
    )
        external
        pure
        returns (
            Game memory,
            Portal[MAX_OPEN_PORTALS] memory,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory,
            uint8,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory,
            uint8,
            bool
        )
    {
        return TimeLib.catchUp(
            g, portals, c, types, oldWord, newWord, storedCoveredEpochs, maxCoveredEpochs, nowTs
        );
    }
}
