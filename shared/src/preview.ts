/**
 * TypeScript mirror of `PortalLab.preview` — the world as of a given moment,
 * without writing anything (SPEC §5).
 *
 * Source of truth is contracts/src/PortalLab.sol and nothing else. Where this
 * file and the Solidity disagree, the mirror is wrong.
 *
 * ── Why this module is three lines of substance ─────────────────────────────
 *
 * `preview` is not a computation of its own. On chain it reads the player's
 * record and hands it to the one catch-up with a very particular pair of
 * arguments:
 *
 *     preview(player)
 *       = _catchUpFree(player, _config, block.timestamp)
 *       = TimeLib.catchUp(storedGame, storedPortals, config, types,
 *                         epochWord, epochWord,          // ONE stored word, twice
 *                         coveredEpochs, coveredEpochs,  // ONE stored limit, twice
 *                         nowTs)
 *
 * Both word arguments are the SAME stored word and both limits are the SAME
 * stored `coveredEpochs`, and that doubling is the whole of it. `catchUp` splits
 * its two words at `storedCoveredEpochs` — old word below, new word at and above
 * — so passing one word twice means "no fresh word has arrived"; and passing the
 * stored coverage as the maximum means "the world may not advance past the epochs
 * already pinned". That is precisely a FREE projection: it costs nothing, asks
 * for no randomness, and stops at the pinned edge, reporting `cappedShort` when
 * it had to.
 *
 * So this module exists to make that argument pairing explicit and testable in
 * one place rather than have each caller repeat it — and to get it wrong
 * differently each time. `catchUp` itself is untouched.
 *
 * ── The contract this upholds ───────────────────────────────────────────────
 *
 * The on-chain NatSpec promises that `preview`'s result equals what an UNPAID
 * `sync` would persist for the same moment. The front end leans on exactly that:
 * it draws the ageing world between transactions from this function, so a
 * divergence would show the player an action that the chain then refuses. The
 * promise is checked on the Solidity side, against real `sync` calls on reachable
 * states, in contracts/test/PreviewMatchesSync.t.sol.
 *
 * ── Argument mutation ───────────────────────────────────────────────────────
 *
 * Like every other exported function in this mirror, `preview` touches nothing it
 * is given: `catchUp` copies the game and the portals before ageing them, so the
 * `StoredPlayer` handed in is still usable afterwards.
 */

import { CatchUpResult, catchUp } from "./time";
import { Config, Game, Portal, PortalTypeParams } from "./types";

/**
 * The part of the on-chain `Player` record a projection needs: the stored game,
 * its twelve portals, the word currently pinned to the player's spawn epochs, and
 * how many epochs that word covers.
 *
 * `epochWord` lives in `Player.epochWord` and `coveredEpochs` in
 * `Pending.coveredEpochs` — the latter sits in the deferral slot for packing
 * reasons but is game state and outlives any deferral, which is why it is read
 * here regardless of whether an action is in flight. The rest of `Pending` has no
 * bearing on a projection.
 */
export interface StoredPlayer {
    game: Game;
    /** Exactly MAX_OPEN_PORTALS (12) portals — the contract's fixed array. */
    portals: readonly Portal[];
    epochWord: bigint;
    coveredEpochs: bigint;
}

/** What `preview` gives back: the three returns of the on-chain function. */
export interface PreviewResult {
    game: Game;
    portals: Portal[];
    /**
     * True when the projection could NOT reach `nowTs` because that would need an
     * epoch no word is pinned to yet. The hour it did reach is in
     * `game.hoursElapsed`; carrying the world further takes a paid `sync` or an
     * `act`.
     */
    cappedShort: boolean;
}

/**
 * Mirror of PortalLab.preview: the world of `stored` as of `nowTs`, projected for
 * free and capped at the pinned-epoch edge.
 *
 * @param stored the player's record, as read from the chain.
 * @param c the immutable configuration, as read from the chain.
 * @param types one PortalTypeParams per PortalType, in enum order (five entries).
 * @param nowTs the moment to project to — on chain this is `block.timestamp`,
 *   which `preview` takes from the block rather than as an argument.
 */
export function preview(
    stored: StoredPlayer,
    c: Config,
    types: readonly PortalTypeParams[],
    nowTs: bigint,
): PreviewResult {
    const r: CatchUpResult = catchUp(
        stored.game,
        stored.portals,
        c,
        types,
        // One stored word in both slots, one stored limit in both: see the note at
        // the top of this file for why that is what "a free projection" means.
        stored.epochWord,
        stored.epochWord,
        stored.coveredEpochs,
        stored.coveredEpochs,
        nowTs,
    );
    // `events` and `spawns` are dropped on purpose: the on-chain `preview` returns
    // three values and no event log. A projection is not a transaction, so nothing
    // it would have emitted happened.
    return { game: r.game, portals: r.portals, cappedShort: r.cappedShort };
}
