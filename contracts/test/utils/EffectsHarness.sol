// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Game, Portal, Config, PortalTypeParams, Action} from "../../src/PortalLabTypes.sol";
import {EffectsLib} from "../../src/EffectsLib.sol";

/// @title EffectsHarness — external face of the internal EffectsLib functions.
/// @notice EffectsLib is a library of internal pure functions, so a revert inside
/// one cannot be caught by the caller. Calling it through this contract makes every
/// call an external one: reverts become catchable (`try/catch`), and — a second
/// benefit — the arguments are ABI-copied, so the library's in-place mutation of its
/// memory structs can never leak back into the caller's inputs.
/// Used by the effects vector generator and by the effects golden test.
contract EffectsHarness {
    function applyAction(Game memory g, Portal memory p, Config memory c, PortalTypeParams memory tp, Action a)
        external
        pure
        returns (Game memory, Portal memory, EffectsLib.Outcome memory)
    {
        return EffectsLib.applyAction(g, p, c, tp, a, address(0));
    }

    function survey(Portal memory p, Config memory c, PortalTypeParams memory tp, uint256 word)
        external
        pure
        returns (Portal memory, bool)
    {
        return EffectsLib.survey(p, c, tp, word);
    }

    function applyBlindRescuerReveal(Game memory g, Portal memory p, Config memory c, uint256 word)
        external
        pure
        returns (Game memory, Portal memory, EffectsLib.Outcome memory)
    {
        return EffectsLib.applyBlindRescuerReveal(g, p, c, word);
    }
}
