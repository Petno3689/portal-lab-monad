// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PortalLab} from "../../src/PortalLab.sol";
import {Game, Portal, MAX_OPEN_PORTALS} from "../../src/PortalLabTypes.sol";
import {DefaultConfig} from "./DefaultConfig.sol";
import {DeterministicSource} from "./DeterministicSource.sol";

/// @title PortalLabHarness — test-only subclass of PortalLab.
/// @notice Exposes `setGame` and `setPortal` so tests can write arbitrary
/// state without going through the full game-start / action flow, plus a
/// `reveal` helper that delivers a pending survey's word through the test
/// `DeterministicSource` (fee 0). These functions MUST NOT exist in production.
contract PortalLabHarness is PortalLab {
    /// @notice The test randomness source (fee 0). Exposed so tests can drive the
    /// reveal timing directly when they need to (e.g. warp between commit and
    /// reveal to exercise the cancellation path).
    DeterministicSource public immutable source;

    constructor()
        PortalLab(DefaultConfig.config(), DefaultConfig.portalTypeParams(), new DeterministicSource(0))
    {
        // Recover the source created in the base-constructor argument above
        // (`_randomSource` is internal, readable by this subclass).
        source = DeterministicSource(address(_randomSource));
    }

    /// @notice Overwrite the stored game for `player`.
    /// @dev Also pins a generous default spawn-epoch coverage and a per-player
    /// word, so mechanics tests that set state directly keep advancing the world
    /// without driving the two-phase epoch machinery (Ticket 4.5). Tests that
    /// exercise the epoch edge call `setCoverage` AFTER this to narrow it.
    function setGame(address player, Game calldata g) external {
        _players[player].game = g;
        _players[player].pending.coveredEpochs = type(uint32).max;
        _players[player].epochWord = uint256(keccak256(abi.encode("portal-lab/harness-word", player)));
    }

    /// @notice Set the spawn-entropy word and covered-epoch count for `player`.
    /// Lets epoch tests pin a known word and a tight covered edge.
    function setCoverage(address player, uint256 word, uint32 coveredEpochs) external {
        _players[player].epochWord = word;
        _players[player].pending.coveredEpochs = coveredEpochs;
    }

    /// @notice Read `player`'s stored spawn-entropy word.
    function epochWordOf(address player) external view returns (uint256) {
        return _players[player].epochWord;
    }

    /// @notice Overwrite a single portal slot for `player`.
    function setPortal(address player, uint8 slot, Portal calldata p) external {
        _players[player].portals[slot] = p;
    }

    /// @notice Deliver the word for `player`'s outstanding deferred survey,
    /// completing (or cancelling) the two-phase flow. Convenience over
    /// `source.reveal(getPending(player).requestId)`.
    function reveal(address player) external {
        source.reveal(_players[player].pending.requestId);
    }
}
