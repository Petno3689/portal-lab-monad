// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RandomStub — PLACEHDOLER pseudo-randomness for Milestone 1.
///
/// @notice ⚠️ THIS IS A STUB, NOT A SECURE SOURCE OF RANDOMNESS. ⚠️
///
/// It exists only so the domain (survey, later spawns) can be built and tested
/// before the real source — **Pyth Entropy V2** — arrives in Milestone 4. The
/// result is a pure `keccak256` of the player's address and a per-game counter,
/// so:
///
///   - **It is fully predictable.** Anyone — the player included — can compute
///     the exact outcome of the next `draw` OFF-CHAIN before sending the
///     transaction. A player can therefore survey ONLY when the roll is
///     favourable (a low-risk result) and skip it otherwise. This is a KNOWN,
///     DELIBERATE hole of the stub, recorded here and in SPEC §6/§11 rather than
///     hidden. It is closed only by real Pyth Entropy, whose value is not known
///     until the fulfillment callback lands (SPEC §6.3).
///
///   - **It must NEVER go to a live network.** Shipping the game on any chain
///     with this stub in place hands players a perfect oracle over the game's
///     "hidden" information. Milestone 4 replaces every call site with the
///     two-phase Pyth request/callback flow.
///
/// @dev The stub is INTENTIONALLY independent of any block-level property (the
/// block time, the prev-randao value, or a block hash). It must be a pure
/// function of its explicit inputs so that the same draw is reproducible in
/// tests and — crucially — in the front-end projection (SPEC §2.1): the client
/// has to be able to recompute exactly what the contract computed. A
/// block-derived value would break that reproducibility, so it is forbidden
/// here. (SPEC §6.6 keeps the full explanation.)
library RandomStub {
    /// @notice One pseudo-random 256-bit word.
    /// @dev UNUSED after Ticket 4.6: blind rescue was the last call site and now
    /// uses `EffectsLib._fromWord` on a delivered Pyth word instead. This function
    /// is kept (not deleted) because test files may reference it directly; removing
    /// it would break those tests. The `rngNonce` increments that used to pair with
    /// this call remain in the production code as vestigial nonce-stream alignment
    /// (reported in Ticket 4.6 deliverables — they are write-only and harmless).
    /// @param player The acting player's address.
    /// @param nonce Per-game roll counter (`Game.rngNonce`).
    /// @param salt Distinguishes several draws within one roll.
    /// @return A pseudo-random word. Predictable off-chain — see the file warning.
    function draw(address player, uint32 nonce, uint8 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(player, nonce, salt)));
    }

    /// @notice Map a random word onto the inclusive range `[lo, hi]`.
    /// @dev `lo + rnd % (hi - lo + 1)`; returns `lo` when `lo == hi` (empty span).
    /// The modulo introduces a negligible bias for these tiny ranges — irrelevant
    /// for a stub, and moot once Pyth replaces it.
    function inRange(uint256 rnd, uint8 lo, uint8 hi) internal pure returns (uint8) {
        if (lo == hi) return lo;
        uint256 span = uint256(hi) - uint256(lo) + 1;
        return uint8(uint256(lo) + (rnd % span));
    }
}
