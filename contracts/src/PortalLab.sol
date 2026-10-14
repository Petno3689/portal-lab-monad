// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Config,
    Game,
    BestRun,
    Player,
    Pending,
    Portal,
    PortalType,
    PortalTypeParams,
    PortalStatus,
    Action,
    Refusal,
    RiskLevel,
    MAX_OPEN_PORTALS,
    MAX_RESCUERS,
    MAX_CATCHUP_EVENTS
} from "./PortalLabTypes.sol";
import {RiskLib} from "./RiskLib.sol";
import {RulesLib} from "./RulesLib.sol";
import {EffectsLib} from "./EffectsLib.sol";
import {TimeLib} from "./TimeLib.sol";
import {IRandomSource, IRandomConsumer} from "./IRandomSource.sol";

/// @title PortalLab — on-chain core of the "Unstable Portals Lab" game (Monad).
/// @notice Ticket 1.1: data model, configuration and game start only. No risk,
/// no actions, no ageing, no spawns, no Pyth, no leaderboard — those are later
/// tickets. See `docs/SPEC.md`.
///
/// @dev Storage layout:
///   - `_config` (Config) and `_portalTypeParams` (PortalTypeParams[5]) are
///     written once in the constructor and never mutated. This is how SPEC §3.4
///     "immutable after deploy" is realised: storage without setters. `immutable`
///     is unusable here because the parameters form structs.
///   - `_players` maps each address to a `Player` that holds their `Game` (2
///     slots) and `Portal[12]` (12 slots) together. A game action touches both,
///     so colocating them in one mapping keeps the hot reads to one contiguous
///     storage region — typically one Monad page (128 slots, SPEC §14.1) — and
///     avoids paying for two separate cold-page loads.
contract PortalLab is IRandomConsumer {
    /// @notice Reverts from the constructor when a configuration value is
    /// invalid. `reason` names the offending field.
    error InvalidConfig(string reason);

    /// @notice Reverts when the random source address given at deploy is zero.
    error ZeroRandomSource();

    /// @notice Reverts when a player tries to act while a two-phase action of
    /// theirs is still awaiting its random word (SPEC §6.3). Only one deferred
    /// action per player at a time.
    error ActionPending();

    /// @notice Reverts when `receiveWord` is called by anyone but the configured
    /// random source (SPEC §6.4) — the gate that stops a chosen word being injected.
    error NotRandomSource();

    /// @notice Reverts when `receiveWord` carries a `requestId` that does not match
    /// the player's outstanding deferred action (SPEC §6.4).
    error UnknownRequest();

    /// @notice Reverts when the value sent with a fee-bearing action is below the
    /// source's required fee. `needed`/`sent` name the amounts.
    error InsufficientFee(uint256 needed, uint256 sent);

    /// @notice Reverts when the ETH change refund to the caller fails.
    error RefundFailed();

    /// @notice Reverts when `RulesLib.check` returns a non-None refusal.
    /// Declared here for ticket 1.5 to use; not yet thrown anywhere.
    error ActionRefused(Refusal reason);

    /// @notice Reverts when `cancelDeferred` finds no outstanding deferral.
    error NoPendingAction();

    /// @notice Reverts when `cancelDeferred` is called before the timeout; `availableAt`
    /// is the first `block.timestamp` at which the cancel is allowed.
    error RequestNotTimedOut(uint256 availableAt);

    /// @notice Reverts when `settle` is called for an address with no active game.
    error NoGame();

    /// @notice Reverts when `settle` is called on a game that is already settled.
    error AlreadySettled();

    /// @notice Reverts when `settle` is called on a game that has not yet ended.
    error GameNotFinished();

    /// @notice A new game began for `player` at `startedAt` (block.timestamp).
    event GameStarted(address indexed player, uint40 startedAt);

    /// @notice An unfinished game was overwritten by a new `startGame` call.
    /// Starting a new game while one is live forfeits the old one (SPEC §8).
    event GameForfeited(address indexed player, uint32 hoursElapsed);

    /// @notice An action was performed on a portal slot. `powerSpent` is the
    /// resource cost that was deducted. `atHour` is the game hour of occurrence
    /// (SPEC §9): under lazy time an event lands in a block later than it happened.
    event ActionPerformed(address indexed player, uint8 indexed slot, Action action, uint16 powerSpent, uint32 atHour);

    /// @notice Creatures were evacuated from a portal, healing HP.
    event CreaturesRescued(address indexed player, uint8 indexed slot, uint8 count, uint16 hpGained, uint32 atHour);

    /// @notice A portal was closed by the player. `deaths` is the beings lost
    /// (creatures plus any crew inside); `hpLost` is the HP the closure cost.
    event PortalClosed(address indexed player, uint8 indexed slot, uint8 deaths, uint16 hpLost, uint32 atHour);

    /// @notice A portal collapsed on its own during catch-up (SPEC §5). `atHour`
    /// is the game hour it collapsed, which is earlier than the block that
    /// records it.
    event PortalCollapsed(address indexed player, uint8 indexed slot, uint8 deaths, uint16 hpLost, uint32 atHour);

    /// @notice A portal appeared during catch-up (SPEC §7). `slot` is the freed
    /// slot it took, `atHour` the game hour it spawned. The name itself is NOT
    /// on-chain — only `nameIndex`; the front end maps the index to a name.
    event PortalSpawned(address indexed player, uint8 indexed slot, PortalType portalType, uint16 nameIndex, uint32 atHour);

    /// @notice A rescuer walked into a portal blind and found it empty, so never
    /// entered (SPEC §4.3). They leave for recovery and rejoin the free pool at
    /// `readyAtHour`. The measurement uses this to count bets that did not pay off.
    event RescuerRecovering(address indexed player, uint8 indexed slot, uint32 readyAtHour);

    /// @notice A portal was surveyed by sending an observer. `precise` is true if
    /// the exact value was read (ranges collapsed to a point), false if a deaf
    /// portal's ranges were only narrowed and a second visit is still needed.
    /// Emitted in the REVEAL phase (SPEC §6.3), i.e. from `receiveWord`.
    event PortalSurveyed(address indexed player, uint8 indexed slot, bool precise, uint32 atHour);

    /// @notice A two-phase survey was COMMITTED: the observer walked in, power was
    /// spent, and a random word was requested (SPEC §6.3). `requestId` matches the
    /// eventual `PortalSurveyed` / `SurveyCancelled`. `atHour` is the commit hour.
    event SurveyRequested(address indexed player, uint8 indexed slot, uint64 requestId, uint32 atHour);

    /// @notice A committed survey was cancelled at reveal because the world changed
    /// underneath it (the portal collapsed in the ~0.6 s wait, or the game ended):
    /// the spent power was refunded (SPEC §6.3, Ticket 4.4 §4.2). `atHour` is the
    /// reveal hour.
    event SurveyCancelled(address indexed player, uint8 indexed slot, uint64 requestId, uint16 powerRefunded, uint32 atHour);

    /// @notice A deferred epoch-crossing action was cancelled at reveal because the
    /// world changed underneath it. `reason` explains why: `PortalEmpty` means the
    /// portal collapsed while the word was in flight; `GameNotActive` means the game
    /// ended in the catch-up window; other codes cover feasibility failures on the
    /// aged world. `requestId` matches the originating commit.
    ///
    /// @dev Unlike `SurveyCancelled` (the legacy in-epoch survey form, Ticket 4.4),
    /// no power is refunded here: the epoch-crossing path spends power only on the
    /// REVEAL side, not at commit. This distinction is intentional and must be
    /// preserved if the two deferral shapes are ever merged.
    event DeferredActionCancelled(
        address indexed player,
        uint8 indexed slot,
        Action action,
        Refusal reason,
        uint64 requestId,
        uint32 atHour
    );

    /// @notice The game ended: HP reached zero. `atHour` is the game hour of death.
    event GameOver(address indexed player, uint32 atHour);

    /// @notice A finished run was recorded in `_bestRun`. Emitted once per settled
    /// run regardless of whether it set a new best. `newBest` is true when
    /// `hoursSurvived` (or the tiebreaking `creaturesRescued`) improved.
    event RunSettled(
        address indexed player,
        uint32 hoursSurvived,
        uint32 creaturesRescued,
        bool newBest
    );

    /// @dev Immutable-after-deploy configuration; see contract-level NatSpec.
    Config private _config;
    /// @dev Per-type balance table, indexed by `PortalType`.
    PortalTypeParams[5] private _portalTypeParams;
    /// @dev One player record per address (game + portals in one mapping entry).
    mapping(address => Player) internal _players;
    /// @dev Permanent best-run record per address. Survives `startGame` resets.
    mapping(address => BestRun) private _bestRun;

    /// @dev The pluggable source of randomness (SPEC §6). Pyth today, anything
    /// tomorrow — swapping it is a redeploy with a different address here, no
    /// change to the game logic. Immutable: the game's honesty rests on a fixed,
    /// known source (SPEC §6.4).
    IRandomSource internal immutable _randomSource;

    /// @param cfg Full game configuration (validated, then stored once).
    /// @param params Per-type parameters, one per `PortalType`, in enum order.
    /// @param randomSource_ The randomness provider (an `IRandomSource`); the only
    ///   address permitted to deliver words via `receiveWord` (SPEC §6.4).
    constructor(Config memory cfg, PortalTypeParams[5] memory params, IRandomSource randomSource_) {
        if (address(randomSource_) == address(0)) revert ZeroRandomSource();
        _randomSource = randomSource_;

        if (cfg.secPerHour == 0) revert InvalidConfig("secPerHour");
        if (cfg.hpMax == 0) revert InvalidConfig("hpMax");
        if (cfg.hpStart == 0) revert InvalidConfig("hpStart");
        if (cfg.hpStart > cfg.hpMax) revert InvalidConfig("hpStart");
        if (cfg.powerMax == 0) revert InvalidConfig("powerMax");
        if (cfg.observersTotal == 0) revert InvalidConfig("observersTotal");
        if (cfg.rescuersTotal == 0) revert InvalidConfig("rescuersTotal");
        // The cooldown ledger has exactly MAX_RESCUERS cells; more rescuers than
        // cells could not all be tracked while recovering (SPEC §4.3).
        if (cfg.rescuersTotal > MAX_RESCUERS) revert InvalidConfig("rescuersTotal");
        // The cooldown must be positive. A cell stores the game hour a rescuer
        // returns, and 0 means "cell free". With a zero cooldown, a blind-empty
        // entry at game hour 0 would write 0 + 0 = 0 — indistinguishable from a
        // free cell, so the recovering rescuer would be lost. Forbid it at deploy.
        if (cfg.rescuerCooldownHours == 0) revert InvalidConfig("rescuerCooldownHours");
        // A portal must cost some pressure, or spawning would divide by zero and
        // never terminate (SPEC §7).
        if (cfg.spawnCostUnits == 0) revert InvalidConfig("spawnCostUnits");
        // Every collapse must cost HP: that is what bounds the number of events one
        // catch-up can meet (a lab cannot keep birthing and collapsing for free),
        // and with it the work of a single call (TimeLib, MAX_CATCHUP_EVENTS).
        if (cfg.hpEmptyCollapse == 0) revert InvalidConfig("hpEmptyCollapse");
        // An epoch must span at least one game hour, or the epoch-of-hour maths
        // (`hour / epochHours`) would divide by zero (Ticket 4.5 §1.4).
        if (cfg.epochHours == 0) revert InvalidConfig("epochHours");
        // A zero timeout would let anyone cancel a deferral the instant it is made.
        if (cfg.requestTimeoutHours == 0) revert InvalidConfig("requestTimeoutHours");
        if (cfg.closeStabilityBelow > 100) revert InvalidConfig("closeStabilityBelow");
        // A rescued creature must not be worth more HP than a lost one — a blunt
        // guard on the balance requirement (SPEC §4.4).
        if (cfg.healPerCreature >= cfg.hpCollapsePerDeath) revert InvalidConfig("healPerCreature");

        for (uint256 i = 0; i < params.length; i++) {
            PortalTypeParams memory p = params[i];
            if (p.hoursMin == 0) revert InvalidConfig("hoursMin");
            if (p.hoursMin > p.hoursMax) revert InvalidConfig("hoursMin>hoursMax");
            if (p.energyMin > p.energyMax) revert InvalidConfig("energyMin>energyMax");
            if (p.energyMax > 100) revert InvalidConfig("energyMax");
            if (p.stabilityMin > p.stabilityMax) revert InvalidConfig("stabilityMin>stabilityMax");
            if (p.stabilityMax > 100) revert InvalidConfig("stabilityMax");
            if (p.creaturesMin > p.creaturesMax) revert InvalidConfig("creaturesMin>creaturesMax");
            if (p.actionMultiplierPct == 0) revert InvalidConfig("actionMultiplierPct");
            _portalTypeParams[i] = p;
        }

        _config = cfg;
    }

    /// @notice Begin a fresh game for `msg.sender`.
    /// @dev If the caller has an unfinished game it is forfeited (SPEC §8). If
    /// they have a finished-but-unsettled game, the result is auto-settled before
    /// the record is deleted, so the run is not lost (SPEC §15). A live game that
    /// is simply abandoned is NOT recorded — the player chose not to engage.
    function startGame() external payable {
        address player = msg.sender;
        Game storage existing = _players[player].game;

        if (existing.startedAt != 0 && !existing.settled) {
            // Config is only needed for the catch-up; load it here, not on the
            // clean-player path which never enters this block.
            Config memory c = _config;
            // Read finished BEFORE catch-up so GameOver is emitted at most once
            // per game: the flag is false on the first detection and true on any
            // subsequent call (sync may have already emitted GameOver).
            bool wasAlreadyFinished = existing.finished;

            // Age the world to now: if the game ended during the absence, detect
            // it. Free/capped — forfeiting an old game must not fetch a word; a
            // deterministic §5.5 death is still seen (it needs none).
            (
                Game memory g,
                ,
                TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
                uint8 collapseCount,
                TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
                uint8 spawnCount,
            ) = _catchUpFree(player, c, uint40(block.timestamp));

            if (g.finished) {
                // Emit catch-up events first, then the death marker, then the
                // settlement — the same order as sync and settle (SPEC §15.4).
                _emitCollapses(player, collapses, collapseCount);
                _emitSpawns(player, catchUpSpawns, spawnCount);
                if (!wasAlreadyFinished) {
                    emit GameOver(player, g.diedAtHour);
                }
                // No storage write before delete: _recordRun reads from memory
                // only, and the delete that follows zeroes all 14 slots anyway.
                // Skipping the write saves ~73 k gas regardless of portal count.
                g.settled = true;
                _recordRun(player, g);
            } else {
                // Game is still alive — the player is forfeiting it. Not recorded.
                // Use the storage hoursElapsed (not the catch-up result) so the
                // emitted value matches what was last persisted, consistent with
                // the forfeit semantics: the player walks away from the stored state.
                emit GameForfeited(player, existing.hoursElapsed);
            }
        }

        // One delete zeroes the entire Player (game + all 12 portal slots).
        delete _players[player];
        Game storage game = _players[player].game;
        // uint40 safely holds seconds until year 36 812; block.timestamp fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 nowTs = uint40(block.timestamp);
        game.startedAt = nowTs;
        game.lastTickAt = nowTs;
        game.hp = _config.hpStart;
        game.power = _config.powerMax;
        game.observersFree = _config.observersTotal;
        game.rescuersFree = _config.rescuersTotal;
        // A starting hand: three portals' worth of pressure is already accrued at
        // hour 0, so three portals are born at hour 0 as soon as epoch 0 is pinned
        // to a word (Ticket 8.1; TimeLib.catchUp births at maturity).
        game.spawnDebt = 3 * _config.spawnCostUnits;
        // hoursElapsed, diedAtHour, openPortals, spawnCount, rngNonce = 0;
        // finished = false — all left at their zeroed defaults.

        emit GameStarted(player, nowTs);

        // Optional fee: buy the first word now, exactly like a paid `sync` that
        // crosses the pinned edge (epoch 0 is not covered on a fresh game). With no
        // value attached nothing is requested and the call behaves as before.
        if (msg.value > 0) {
            if (_players[player].pending.active) revert ActionPending();
            uint256 f = _randomSource.fee();
            if (msg.value < f) revert InsufficientFee(f, msg.value);

            _players[player].pending = Pending({
                active: true,
                action: Action.ToggleQuestioned, // unused (syncOnly); a harmless default
                slot: 0,
                atHour: 0,
                requestId: 0,
                coveredEpochs: _players[player].pending.coveredEpochs,
                deferredWorld: true,
                syncOnly: true,
                committedAt: nowTs
            });
            uint64 requestId = _randomSource.requestWord{value: f}(player);
            _players[player].pending.requestId = requestId;

            if (msg.value > f) _refund(msg.sender, msg.value - f);
        }
    }

    /// @notice Perform `action` on portal `slot` for `msg.sender`.
    /// @dev The world is aged to `block.timestamp` FIRST (SPEC §5), so both
    /// feasibility and effects see the current world:
    ///   1. Catch up game + portals to now (in memory).
    ///   2. If the catch-up finished the game (HP hit zero while away, or the
    ///      game was already over), revert `ActionRefused(GameNotActive)`. The
    ///      catch-up is not persisted on this path; a later `sync` (open to
    ///      anyone) records the death and emits its events — nothing is lost,
    ///      because the aged state is a pure function of the snapshot and time.
    ///   3. `RulesLib.check` on the aged state; a refusal reverts. A portal that
    ///      collapsed during catch-up is now `Empty`, so acting on it yields
    ///      `PortalEmpty`; a portal that only just became closable by time now
    ///      passes.
    ///   4. Deduct cost, apply the effect, detect death from one's own action.
    ///   5. Persist the caught-up state WITH the action applied, then emit the
    ///      catch-up collapse events followed by the action events. Emitting only
    ///      on the successful path keeps the transaction atomic; a refused action
    ///      reverts the catch-up too, to be redone by the next state-advancing call.
    /// Sending an observer into an UNSURVEYED portal is TWO-PHASE (SPEC §6.3): the
    /// survey draws a random word, so this call only COMMITS it (observer in, power
    /// spent, word requested, deferred state recorded) and `receiveWord` completes
    /// it. The call is `payable` so the player can forward the source's fee; any
    /// excess over the fee is refunded. While a deferred action is outstanding, any
    /// further action by the same player is refused (`ActionPending`).
    function act(uint8 slot, Action action) external payable {
        address player = msg.sender;

        // One deferred action per player (SPEC §6.3).
        if (_players[player].pending.active) revert ActionPending();

        Config memory c = _config;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
            bool cappedShort
        ) = _catchUpFree(player, c, uint40(block.timestamp));

        // The game may have ended during catch-up (or was already over). A §5.5
        // death beyond the pinned edge is deterministic, so this is caught without
        // a word and the player is not charged for one.
        if (g.finished) revert ActionRefused(Refusal.GameNotActive);

        // Crossing the pinned-epoch edge: the catch-up itself needs a fresh word
        // for the spawns in the new epochs, so the WHOLE action defers (Ticket 4.5
        // §4.2/§4.3). One word covers every crossed epoch and, if the action rolls
        // (a survey), that same word serves it too — never two requests (§4.3).
        if (cappedShort) {
            uint256 f = _randomSource.fee();
            if (msg.value < f) revert InsufficientFee(f, msg.value);

            // Lock and record the deferral. The world is NOT advanced here; the
            // reveal re-ages it in full (old word for already-pinned epochs, the
            // new word beyond) and only then applies the action. `atHour` is the
            // pinned-edge hour the probe reached, for the front end's reference.
            _players[player].pending = Pending({
                active: true,
                action: action,
                slot: slot,
                atHour: g.hoursElapsed,
                requestId: 0,
                coveredEpochs: _players[player].pending.coveredEpochs,
                deferredWorld: true,
                syncOnly: false,
                committedAt: uint40(block.timestamp)
            });
            uint64 reqId = _randomSource.requestWord{value: f}(player);
            _players[player].pending.requestId = reqId;

            if (msg.value > f) _refund(player, msg.value - f);
            return;
        }

        Portal memory p;
        if (slot < MAX_OPEN_PORTALS) {
            p = portals[slot];
        }

        // Feasibility on the aged state.
        Refusal reason = RulesLib.check(g, p, c, slot, action);
        if (reason != Refusal.None) revert ActionRefused(reason);

        // Cost, then effect.
        uint16 powerSpent = RulesLib.cost(c, action);
        g.power -= powerSpent;

        // ── Two-phase survey COMMIT ──────────────────────────────────────────
        if (action == Action.SendObserver && !p.surveyed) {
            // Scope the fee check so `fee` is freed before the storage write.
            // Writing a 12-element Portal array (each portal 22 memory words)
            // generates a packing loop with 5 Yul variables.  Keeping `fee`
            // alive across that write would push the EVM stack past 16 slots.
            // Re-fetching after the writes is safe: fee cannot change within one
            // transaction.
            {
                uint256 fee = _randomSource.fee();
                if (msg.value < fee) revert InsufficientFee(fee, msg.value);
            }

            // The observer walks in now; the reading arrives on reveal.
            p.observerInside = true;
            g.observersFree -= 1;
            p.surveyPending = true;
            // Advance the per-game roll counter on every survey, as before, so the
            // stub-fed consumers (spawns, blind rescue) see an unchanged nonce
            // stream across this change. The survey VALUE now derives from the
            // delivered word, not from rngNonce (SPEC §6.3, Ticket 4.4 §2.3).
            g.rngNonce += 1;
            _setPortal(portals, slot, p);

            // Checks-effects-interactions: write all effects (state + lock) before
            // the external requestWord call. The lock (pending.active = true) is
            // set here so a reentrant act would hit ActionPending even if
            // requestWord somehow fired a callback synchronously.
            _players[player].game = g;
            _players[player].portals = portals;
            // Legacy in-epoch survey deferral (Ticket 4.4): the world is already
            // aged (persisted above) and the observer walked in; the reveal only
            // writes the survey draws. `deferredWorld = false` marks this shape.
            // Coverage is unchanged — no epoch was crossed.
            _players[player].pending = Pending({
                active: true,
                action: Action.SendObserver,
                slot: slot,
                atHour: g.hoursElapsed,
                requestId: 0,
                coveredEpochs: _players[player].pending.coveredEpochs,
                deferredWorld: false,
                syncOnly: false,
                committedAt: uint40(block.timestamp)
            });

            uint256 f = _randomSource.fee();
            uint64 requestId = _randomSource.requestWord{value: f}(player);

            _players[player].pending.requestId = requestId;

            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            emit ActionPerformed(player, slot, action, powerSpent, g.hoursElapsed);
            emit SurveyRequested(player, slot, requestId, g.hoursElapsed);

            if (msg.value > f) _refund(player, msg.value - f);
            return;
        }

        // ── Two-phase blind rescue COMMIT ────────────────────────────────────
        // Sending a rescuer into an UNSURVEYED portal triggers a two-phase flow:
        // power and one rescuer are committed now, and the creature count is
        // resolved on word delivery. Sighted rescues (creaturesKnown == true)
        // fall through to the single-phase path below.
        if (action == Action.SendRescuer && !p.creaturesKnown) {
            // Same scoping rationale as the survey COMMIT above: free `fee` before
            // the storage write to stay within the 16-slot EVM stack budget.
            {
                uint256 fee = _randomSource.fee();
                if (msg.value < fee) revert InsufficientFee(fee, msg.value);
            }

            // Keep the nonce stream aligned (vestigial after Ticket 4.6 — rngNonce
            // is write-only at this point, but incrementing it here means the
            // stream matches the old single-phase cadence for any future analysis).
            g.rngNonce += 1;
            // Rescuer leaves the base at COMMIT regardless of outcome (SPEC §4.3).
            g.rescuersFree -= 1;
            p.rescuerPending = true;
            _setPortal(portals, slot, p);

            _players[player].game = g;
            _players[player].portals = portals;
            _players[player].pending = Pending({
                active: true,
                action: Action.SendRescuer,
                slot: slot,
                atHour: g.hoursElapsed,
                requestId: 0,
                coveredEpochs: _players[player].pending.coveredEpochs,
                deferredWorld: false,
                syncOnly: false,
                committedAt: uint40(block.timestamp)
            });

            uint256 f = _randomSource.fee();
            uint64 requestId = _randomSource.requestWord{value: f}(player);
            _players[player].pending.requestId = requestId;

            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            emit ActionPerformed(player, slot, action, powerSpent, g.hoursElapsed);

            if (msg.value > f) _refund(player, msg.value - f);
            return;
        }

        // ── Single-phase path (everything else) ──────────────────────────────
        PortalTypeParams memory tp = _portalTypeParams[uint256(uint8(p.portalType))];
        EffectsLib.Outcome memory outcome;
        (g, p, outcome) = EffectsLib.applyAction(g, p, c, tp, action, player);
        _setPortal(portals, slot, p);

        // Death from one's own action (only Close can lower HP).
        bool gameOver = g.hp == 0;
        if (gameOver) {
            g.finished = true;
            g.diedAtHour = g.hoursElapsed;
        }

        // Persist the caught-up world with the action applied.
        _players[player].game = g;
        _players[player].portals = portals;

        // Emit catch-up collapses and spawns first (they happened before the
        // action, during the window this call caught up).
        _emitCollapses(player, collapses, collapseCount);
        _emitSpawns(player, catchUpSpawns, spawnCount);

        uint32 atHour = g.hoursElapsed;
        emit ActionPerformed(player, slot, action, powerSpent, atHour);
        if (outcome.surveyDone) {
            emit PortalSurveyed(player, slot, outcome.surveyPrecise, atHour);
        }
        if (action == Action.Evacuate) {
            emit CreaturesRescued(player, slot, outcome.rescued, outcome.hpGained, atHour);
        } else if (action == Action.Close) {
            emit PortalClosed(player, slot, outcome.deaths, outcome.hpLost, atHour);
        }
        if (outcome.rescuerBlindMiss) {
            emit RescuerRecovering(player, slot, outcome.rescuerReadyAtHour);
        }
        if (gameOver) {
            emit GameOver(player, g.diedAtHour);
        }

        // Defensive: a non-survey action needs no fee; refund any value sent by
        // mistake rather than stranding it in the contract.
        if (msg.value > 0) _refund(player, msg.value);
    }

    /// @notice REVEAL phase of a two-phase action (SPEC §6.3): the random source
    /// delivers the `word` for a previously committed deferral.
    /// @dev Trust gate (SPEC §6.4): only the configured source may call, and the
    /// `requestId` must match the player's outstanding deferral. There are two
    /// deferral shapes (see `Pending`):
    ///
    ///   - `deferredWorld == false` — the legacy in-epoch survey (Ticket 4.4):
    ///     the world was already aged and the observer committed; this call only
    ///     ages the sub-hour gap and writes the survey draws, or cancels (refunding
    ///     the spent power) if the portal collapsed or the game ended meanwhile.
    ///
    ///   - `deferredWorld == true` — an epoch-crossing deferral (Ticket 4.5): the
    ///     world was NOT aged at commit because the catch-up needed this word for
    ///     the new epochs' spawns. This call ages the world in FULL — old word for
    ///     epochs already pinned (`< coveredEpochs`), the delivered word beyond
    ///     (§2.3) — pins the new coverage, and only THEN applies the deferred
    ///     action (or nothing, for a paid-sync `syncOnly` deferral).
    function receiveWord(address player, uint64 requestId, uint256 word) external {
        if (msg.sender != address(_randomSource)) revert NotRandomSource();

        Pending memory pend = _players[player].pending;
        if (!pend.active || pend.requestId != requestId) revert UnknownRequest();

        if (pend.deferredWorld) {
            _revealCrossing(player, pend, word);
        } else if (pend.action == Action.SendObserver) {
            _revealSurvey(player, pend, requestId, word);
        } else {
            // Action.SendRescuer — in-epoch blind rescue reveal (Ticket 4.6).
            _revealBlindRescue(player, pend, requestId, word);
        }
    }

    /// @dev Legacy in-epoch survey reveal (Ticket 4.4). Ages the sub-hour gap
    /// (capped — no epoch was crossed), applies the survey draws from `word`, or
    /// cancels with a power refund if the portal collapsed / the game ended.
    function _revealSurvey(address player, Pending memory pend, uint64 requestId, uint256 word) private {
        Config memory c = _config;
        bool wasAlreadyFinished = _players[player].game.finished;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
        ) = _catchUpFree(player, c, uint40(block.timestamp));

        // Resolve the deferral but PRESERVE coverage (a `delete` would wipe it).
        _clearPending(player, _players[player].pending.coveredEpochs);

        uint8 slot = pend.slot;
        uint32 atHour = g.hoursElapsed;

        bool stillLegal = !g.finished && slot < MAX_OPEN_PORTALS && portals[slot].surveyPending;

        if (stillLegal) {
            Portal memory p = portals[slot];
            PortalTypeParams memory tp = _portalTypeParams[uint256(uint8(p.portalType))];
            bool precise;
            (p, precise) = EffectsLib.survey(p, c, tp, word);
            p.surveyPending = false;
            _setPortal(portals, slot, p);

            _players[player].game = g;
            _players[player].portals = portals;

            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            emit PortalSurveyed(player, slot, precise, atHour);
        } else {
            uint16 refund = RulesLib.cost(c, Action.SendObserver);
            uint256 restored = uint256(g.power) + uint256(refund);
            if (restored > c.powerMax) restored = c.powerMax;
            g.power = uint16(restored);

            if (slot < MAX_OPEN_PORTALS && portals[slot].surveyPending) {
                portals[slot].surveyPending = false;
            }

            _players[player].game = g;
            _players[player].portals = portals;

            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            if (g.finished && !wasAlreadyFinished) {
                emit GameOver(player, g.diedAtHour);
            }
            emit SurveyCancelled(player, slot, requestId, refund, atHour);
        }
    }

    /// @dev In-epoch blind rescue REVEAL (Ticket 4.6). Ages the sub-hour gap,
    /// applies the creature-count roll from `word`, or cancels if the portal
    /// collapsed / the game ended while the word was in flight.
    ///
    /// CANCEL SEMANTICS: unlike `_revealSurvey` where the observer was ALREADY
    /// INSIDE the portal (and perishes with it on collapse), the rescuer had NOT
    /// yet entered — they were in transit. On cancel the rescuer returns to the
    /// free pool AND the spent power is refunded. This asymmetry is intentional:
    /// the rescuer only enters on REVEAL, so a mid-flight collapse returns them
    /// safely. Contrast with SurveyCancelled which refunds power but NOT the crew.
    function _revealBlindRescue(address player, Pending memory pend, uint64 requestId, uint256 word) private {
        Config memory c = _config;
        bool wasAlreadyFinished = _players[player].game.finished;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
        ) = _catchUpFree(player, c, uint40(block.timestamp));

        _clearPending(player, _players[player].pending.coveredEpochs);

        uint8 slot = pend.slot;
        uint32 atHour = g.hoursElapsed;
        bool stillLegal = !g.finished && slot < MAX_OPEN_PORTALS && portals[slot].rescuerPending;

        if (stillLegal) {
            Portal memory p = portals[slot];
            p.rescuerPending = false;
            EffectsLib.Outcome memory outcome;
            (g, p, outcome) = EffectsLib.applyBlindRescuerReveal(g, p, c, word);
            _setPortal(portals, slot, p);

            bool gameOver = g.hp == 0;
            if (gameOver) {
                g.finished = true;
                g.diedAtHour = g.hoursElapsed;
            }

            _players[player].game = g;
            _players[player].portals = portals;
            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            if (outcome.rescuerBlindMiss) emit RescuerRecovering(player, slot, outcome.rescuerReadyAtHour);
            if (gameOver) emit GameOver(player, g.diedAtHour);
        } else {
            // CANCEL: portal collapsed (or game ended) while the word was in flight.
            // Power is refunded. The rescuer returns to the free pool — unlike the
            // observer cancel (SurveyCancelled) where the observer was ALREADY INSIDE
            // the portal and perishes with it. The rescuer had NOT entered (entry only
            // happens on REVEAL), so they return safely from the aborted mission.
            uint16 refund = RulesLib.cost(c, Action.SendRescuer);
            uint256 restored = uint256(g.power) + uint256(refund);
            if (restored > c.powerMax) restored = c.powerMax;
            g.power = uint16(restored);
            g.rescuersFree += 1;

            if (slot < MAX_OPEN_PORTALS && portals[slot].rescuerPending) {
                portals[slot].rescuerPending = false;
            }

            _players[player].game = g;
            _players[player].portals = portals;
            _emitCollapses(player, collapses, collapseCount);
            _emitSpawns(player, catchUpSpawns, spawnCount);
            if (g.finished && !wasAlreadyFinished) emit GameOver(player, g.diedAtHour);

            Refusal reason = g.finished ? Refusal.GameNotActive : Refusal.PortalEmpty;
            emit DeferredActionCancelled(player, slot, Action.SendRescuer, reason, requestId, atHour);
        }
    }

    /// @dev Epoch-crossing reveal (Ticket 4.5). Ages the world in full with the
    /// old/new word split, pins the new coverage, then applies the deferred action
    /// (unless `syncOnly`). A death in the aged window ends the run before any
    /// action. An action no longer legal on the aged world is cancelled silently —
    /// a crossing deferral spent nothing at commit, so there is nothing to refund.
    function _revealCrossing(address player, Pending memory pend, uint256 word) private {
        Config memory c = _config;
        bool wasAlreadyFinished = _players[player].game.finished;

        uint40 nowTs = uint40(block.timestamp);
        uint256 oldWord = _players[player].epochWord;
        uint32 storedCovered = pend.coveredEpochs;
        uint32 newCovered = _epochOf(c, _players[player].game.startedAt, nowTs) + 1;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
        ) = _catchUp(player, c, oldWord, word, storedCovered, newCovered, nowTs);

        // Pin the delivered word and the new coverage, and resolve the deferral.
        // Done before any early return so the pinning always stands (the past is
        // never recomputed, §2.2). `newCovered` is correct even on a death — the
        // frozen world simply never enters further epochs.
        _players[player].epochWord = word;
        _clearPending(player, newCovered);

        _players[player].game = g;
        _players[player].portals = portals;

        _emitCollapses(player, collapses, collapseCount);
        _emitSpawns(player, catchUpSpawns, spawnCount);

        if (g.finished) {
            if (!wasAlreadyFinished) emit GameOver(player, g.diedAtHour);
            // A syncOnly deferral carries no action — silence is intentional when
            // a paid sync just lost the race with a game-ending collapse.
            if (!pend.syncOnly) {
                emit DeferredActionCancelled(
                    player, pend.slot, pend.action, Refusal.GameNotActive,
                    pend.requestId, g.hoursElapsed
                );
            }
            return;
        }

        // A paid-sync deferral carries no action — the world advancement was the
        // whole point; nothing to cancel.
        if (pend.syncOnly) return;

        (g, portals) = _performDeferredAction(player, g, portals, c, pend.slot, pend.action, word, pend.requestId);
        _players[player].game = g;
        _players[player].portals = portals;
    }

    /// @dev Epoch-crossing survey: extracted from `_performDeferredAction` so that
    /// function carries no `portals[slot] = p` copy and stays within Yul stack limits.
    /// The Portal struct has 22 memory words; at that size the Yul IR backend switches
    /// from inline mstores to a loop, adding ~4 stack variables. `_performDeferredAction`
    /// has 8 params + several locals — delegating both copy sites keeps every frame ≤ 16.
    function _applyEpochCrossingSurvey(
        address player,
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        Portal memory p,
        uint8 slot,
        PortalTypeParams memory tp,
        uint256 word,
        uint16 powerSpent,
        uint32 atHour
    ) private returns (Game memory, Portal[MAX_OPEN_PORTALS] memory) {
        p.observerInside = true;
        g.observersFree -= 1;
        g.rngNonce += 1; // keep the nonce stream aligned (see TimeLib._birth)
        bool precise;
        (p, precise) = EffectsLib.survey(p, c, tp, word);
        _setPortal(portals, slot, p);
        emit ActionPerformed(player, slot, Action.SendObserver, powerSpent, atHour);
        emit PortalSurveyed(player, slot, precise, atHour);
        return (g, portals);
    }

    /// @dev Epoch-crossing generic-action path (all actions except survey and blind
    /// rescue): extracted from `_performDeferredAction` for the same Yul stack reason
    /// as `_applyEpochCrossingSurvey` — `word` and `requestId` are not needed here,
    /// so excluding them frees two stack slots and keeps the frame under the limit.
    function _applyGenericDeferredAction(
        address player,
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        Portal memory p,
        uint8 slot,
        Action action,
        PortalTypeParams memory tp,
        uint16 powerSpent,
        uint32 atHour
    ) private returns (Game memory, Portal[MAX_OPEN_PORTALS] memory) {
        EffectsLib.Outcome memory outcome;
        (g, p, outcome) = EffectsLib.applyAction(g, p, c, tp, action, player);
        _setPortal(portals, slot, p);

        bool gameOver = g.hp == 0;
        if (gameOver) {
            g.finished = true;
            g.diedAtHour = g.hoursElapsed;
        }

        emit ActionPerformed(player, slot, action, powerSpent, atHour);
        if (outcome.surveyDone) {
            emit PortalSurveyed(player, slot, outcome.surveyPrecise, atHour);
        }
        if (action == Action.Evacuate) {
            emit CreaturesRescued(player, slot, outcome.rescued, outcome.hpGained, atHour);
        } else if (action == Action.Close) {
            emit PortalClosed(player, slot, outcome.deaths, outcome.hpLost, atHour);
        }
        if (outcome.rescuerBlindMiss) {
            emit RescuerRecovering(player, slot, outcome.rescuerReadyAtHour);
        }
        if (gameOver) {
            emit GameOver(player, g.diedAtHour);
        }

        return (g, portals);
    }

    /// @dev Epoch-crossing blind rescue logic, extracted from `_performDeferredAction`
    /// to keep that function's local-variable count within Yul stack limits.
    /// At epoch-crossing, the commit left state untouched; this call handles the
    /// full cost (power already deducted by the caller) and the creature-count roll.
    function _applyEpochCrossingBlindRescue(
        address player,
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        Portal memory p,
        uint8 slot,
        uint256 word,
        uint16 powerSpent,
        uint32 atHour
    ) private returns (Game memory, Portal[MAX_OPEN_PORTALS] memory) {
        g.rngNonce += 1; // keep nonce stream aligned (vestigial after Ticket 4.6)
        g.rescuersFree -= 1; // commit touched nothing; decrement now
        EffectsLib.Outcome memory blindOutcome;
        (g, p, blindOutcome) = EffectsLib.applyBlindRescuerReveal(g, p, c, word);
        _setPortal(portals, slot, p);
        bool gameOver = g.hp == 0;
        if (gameOver) { g.finished = true; g.diedAtHour = g.hoursElapsed; }
        emit ActionPerformed(player, slot, Action.SendRescuer, powerSpent, atHour);
        if (blindOutcome.rescuerBlindMiss) emit RescuerRecovering(player, slot, blindOutcome.rescuerReadyAtHour);
        if (gameOver) emit GameOver(player, g.diedAtHour);
        return (g, portals);
    }

    /// @notice Cancel a deferral whose random word never arrived (Ticket 4.7).
    /// Callable by ANYONE for any player, once `requestTimeoutHours` of REAL time
    /// have passed since the commit.
    /// @dev The clock is `block.timestamp - committedAt`, NOT game hours. An
    /// epoch-crossing deferral is stuck precisely because the world cannot age
    /// past the pinned edge, so game hours are frozen then; a game-hour timeout
    /// would never fire in the very case it exists for.
    ///
    /// Refunds: the provider fee is never returned (it already left the contract).
    /// Power comes back only where it was taken at commit (half, rounded up in the
    /// player's favour). An epoch-crossing deferral (`deferredWorld`) takes power
    /// only on reveal: the expedition never set out, so there is nothing to give back.
    ///
    /// Crew return ALIVE, unlike a collapse-cancel: there the portal is gone and an
    /// observer inside dies with it; here the portal is intact, the observer simply
    /// walks back out. A rescuer never went in before the reveal.
    function cancelDeferred(address player) external {
        Pending memory pend = _players[player].pending;
        if (!pend.active) revert NoPendingAction();

        Config memory c = _config;
        uint256 availableAt = uint256(pend.committedAt) + uint256(c.requestTimeoutHours) * uint256(c.secPerHour);
        if (block.timestamp <= availableAt) revert RequestNotTimedOut(availableAt + 1);

        // Every path brings the world up to date, like every other mutating entry
        // point. Free catch-up, no word, stops at the pinned edge. On the crew-return
        // path this is also what decisions are taken on: never on raw storage, or the
        // outcome would depend on whether anyone called `sync` first (a collapsed
        // portal's observer is dead only once the world has been aged).
        bool wasAlreadyFinished = _players[player].game.finished;
        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
        ) = _catchUpFree(player, c, uint40(block.timestamp));

        if (!pend.syncOnly && !pend.deferredWorld) {
            if (pend.slot < MAX_OPEN_PORTALS) {
                Portal memory p = portals[pend.slot];
                if (pend.action == Action.SendObserver) {
                    // Only if the observer is still inside (a collapse during
                    // catch-up already counted him among the dead).
                    if (p.surveyPending) {
                        p.surveyPending = false;
                        p.observerInside = false;
                        g.observersFree += 1;
                    }
                } else {
                    // Rescuer never entered, so he is returned regardless.
                    p.rescuerPending = false;
                    g.rescuersFree += 1;
                }
                _setPortal(portals, pend.slot, p);
            }
            // Power is refunded uniformly, even to a game the catch-up just ended
            // (harmless on a finished run).
            uint256 restored = uint256(g.power) + (uint256(RulesLib.cost(c, pend.action)) + 1) / 2;
            g.power = uint16(restored > c.powerMax ? c.powerMax : restored);
        }

        _players[player].game = g;
        _players[player].portals = portals;
        _emitCollapses(player, collapses, collapseCount);
        _emitSpawns(player, catchUpSpawns, spawnCount);
        if (g.finished && !wasAlreadyFinished) emit GameOver(player, g.diedAtHour);

        _clearPending(player, pend.coveredEpochs);
        emit DeferredActionCancelled(
            player, pend.slot, pend.action, Refusal.RandomnessTimeout, pend.requestId, pend.atHour
        );
    }

    /// @dev Reset the deferral fields of `player`'s pending slot while preserving
    /// `coveredEpochs` (game state that must outlive the deferral). A `delete`
    /// would zero the whole slot, wiping coverage.
    function _clearPending(address player, uint32 coveredEpochs) private {
        Pending storage pnd = _players[player].pending;
        pnd.active = false;
        pnd.action = Action.ToggleQuestioned;
        pnd.slot = 0;
        pnd.atHour = 0;
        pnd.requestId = 0;
        pnd.deferredWorld = false;
        pnd.syncOnly = false;
        pnd.committedAt = 0;
        pnd.coveredEpochs = coveredEpochs;
    }

    /// @dev Apply a deferred game action on the fully-aged world, emitting the
    /// same events `act` would. `SendObserver` into an unsurveyed portal is
    /// surveyed in place with the delivered `word` (no second request, §4.3) —
    /// the spawn and survey derivations are domain-separated so they never collide
    /// (§3.2). An action no longer legal on the aged world emits `DeferredActionCancelled`
    /// and returns without mutating state — no power was spent at commit, so nothing
    /// is refunded (contrast with `SurveyCancelled` which refunds the observer cost).
    function _performDeferredAction(
        address player,
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        uint8 slot,
        Action action,
        uint256 word,
        uint64 requestId
    ) private returns (Game memory, Portal[MAX_OPEN_PORTALS] memory) {
        Portal memory p;
        if (slot < MAX_OPEN_PORTALS) {
            p = portals[slot];
        }

        Refusal reason = RulesLib.check(g, p, c, slot, action);
        if (reason != Refusal.None) {
            // No longer legal on the aged world (e.g. the portal collapsed while
            // the word was in flight). Nothing was spent at commit, nothing to
            // refund; the world ageing stands. Emit so the front end knows the
            // reason — "portal gone" vs "not enough power" are very different.
            emit DeferredActionCancelled(player, slot, action, reason, requestId, g.hoursElapsed);
            return (g, portals);
        }

        uint16 powerSpent = RulesLib.cost(c, action);
        g.power -= powerSpent;
        uint32 atHour = g.hoursElapsed;
        PortalTypeParams memory tp = _portalTypeParams[uint256(uint8(p.portalType))];

        if (action == Action.SendObserver && !p.surveyed) {
            // Delegated: portals[slot]=p inside a helper keeps this frame under
            // the Yul 16-slot stack limit (22-word Portal struct triggers loop copy).
            return _applyEpochCrossingSurvey(player, g, portals, c, p, slot, tp, word, powerSpent, atHour);
        }

        // Epoch-crossing blind rescue: the commit touched nothing (world not aged),
        // so power and rescuersFree are handled HERE, not at commit.
        if (action == Action.SendRescuer && !p.creaturesKnown) {
            return _applyEpochCrossingBlindRescue(player, g, portals, c, p, slot, word, powerSpent, atHour);
        }

        // All other actions (Stabilize, Destabilize, RecallObserver, RecallRescuer,
        // Evacuate, Close, sighted SendRescuer). Delegated for same stack-depth reason.
        return _applyGenericDeferredAction(player, g, portals, c, p, slot, action, tp, powerSpent, atHour);
    }

    /// @dev Reference-assign `p` into `portals[slot]`. Kept out of line so callers
    /// stay under the Yul stack limit; the array holds pointers, not inline structs.
    function _setPortal(Portal[MAX_OPEN_PORTALS] memory portals, uint256 slot, Portal memory p) private pure {
        portals[slot] = p;
    }

    /// @dev Refund `amount` of the native coin to `to` (change above the fee, or a
    /// fee mistakenly attached to a non-survey action). Done last, after state is
    /// written; a reentrant `act` is blocked by the `ActionPending` lock while a
    /// survey is outstanding.
    function _refund(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    /// @notice Age `player`'s world to `block.timestamp` and persist it, without
    /// performing any game action.
    /// @dev Callable by ANYONE: the catch-up is deterministic and cannot harm the
    /// player, and an external "alarm clock" may nudge the world forward without
    /// changing the contract. Emits the collapse events and `GameOver` if the
    /// game ended in this call.
    ///
    /// UNPAID (`msg.value == 0`): ages the world to the pinned-epoch edge and
    /// stops (Ticket 4.5 §4.4). Free, requests no word. A deterministic §5.5
    /// death beyond the edge is still detected — it needs no randomness.
    ///
    /// PAID (`msg.value > 0`, §4.4 amended): if the world hits the pinned edge
    /// while still alive, `sync` fetches a fresh word and goes two-phase exactly
    /// like `act`, carrying the world across the edge on the matching
    /// `receiveWord`. The deferral is recorded on `player`; the FEE is paid by —
    /// and any change returned to — the CALLER, never the player. No one is ever
    /// obliged to pay for another's game: the unpaid path stays open to all. If
    /// the player already has a deferral, a paid `sync` is refused `ActionPending`.
    function sync(address player) external payable {
        Config memory c = _config;
        bool wasFinished = _players[player].game.finished;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
            bool cappedShort
        ) = _catchUpFree(player, c, uint40(block.timestamp));

        // Paid path: carry the world across the pinned edge with a fresh word.
        if (msg.value > 0 && !g.finished && cappedShort) {
            if (_players[player].pending.active) revert ActionPending();
            uint256 f = _randomSource.fee();
            if (msg.value < f) revert InsufficientFee(f, msg.value);

            // Record the deferral on the PLAYER; a paid sync carries no action.
            _players[player].pending = Pending({
                active: true,
                action: Action.ToggleQuestioned, // unused (syncOnly); a harmless default
                slot: 0,
                atHour: g.hoursElapsed,
                requestId: 0,
                coveredEpochs: _players[player].pending.coveredEpochs,
                deferredWorld: true,
                syncOnly: true,
                committedAt: uint40(block.timestamp)
            });
            uint64 requestId = _randomSource.requestWord{value: f}(player);
            _players[player].pending.requestId = requestId;

            // The world advancement and events all land on the reveal. Change to
            // the caller.
            if (msg.value > f) _refund(msg.sender, msg.value - f);
            return;
        }

        // Free/unpaid path (and the paid path when no word is needed — e.g. the
        // world reached now, or a deterministic death ended it): persist and emit.
        _players[player].game = g;
        _players[player].portals = portals;

        _emitCollapses(player, collapses, collapseCount);
        _emitSpawns(player, catchUpSpawns, spawnCount);
        if (g.finished && !wasFinished) {
            emit GameOver(player, g.diedAtHour);
        }

        // A fee attached to a call that needed no word is fully returned to the
        // caller — they are never charged for a no-op.
        if (msg.value > 0) _refund(msg.sender, msg.value);
    }

    /// @notice Record the result of `player`'s finished run in `_bestRun`.
    /// @dev Callable by ANYONE for any player (SPEC §15). This allows an external
    /// "alarm clock" to settle a run on behalf of a player who has gone offline.
    ///   a) No game (startedAt == 0) → NoGame.
    ///   b) Already settled → AlreadySettled.
    ///   c) Catch up to now — the game may have ended during absence.
    ///   d) Still alive after catch-up → GameNotFinished.
    ///   e) Persist caught-up state, mark settled, record result, emit RunSettled.
    function settle(address player) public {
        Game storage existing = _players[player].game;
        if (existing.startedAt == 0) revert NoGame();
        if (existing.settled) revert AlreadySettled();
        // Snapshot finished BEFORE catch-up: if the game was already dead (e.g.
        // a prior sync emitted GameOver), we must not emit it a second time.
        bool wasAlreadyFinished = existing.finished;

        (
            Game memory g,
            Portal[MAX_OPEN_PORTALS] memory portals,
            TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
            uint8 collapseCount,
            TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory catchUpSpawns,
            uint8 spawnCount,
        ) = _catchUpFree(player, _config, uint40(block.timestamp));

        // settle never fetches a word (Ticket 4.5 §4.4): it ages the world to the
        // pinned edge and no further. A death BEFORE the edge — or the
        // randomness-free §5.5 long-absence overflow — is detected here; a run
        // still alive at the edge is simply unfinished and honestly refused.
        if (!g.finished) revert GameNotFinished();

        g.settled = true;
        _players[player].game = g;
        _players[player].portals = portals;

        _emitCollapses(player, collapses, collapseCount);
        _emitSpawns(player, catchUpSpawns, spawnCount);
        if (!wasAlreadyFinished) {
            emit GameOver(player, g.diedAtHour);
        }

        _recordRun(player, g);
    }

    /// @dev Write `g`'s result to `_bestRun[player]` and emit `RunSettled`.
    /// Called from both `settle` and the auto-settle path in `startGame`.
    function _recordRun(address player, Game memory g) internal {
        BestRun storage best = _bestRun[player];
        uint32 hrs = g.diedAtHour;
        uint32 rescued = g.creaturesRescued;
        bool newBest = hrs > best.hoursSurvived
            || (hrs == best.hoursSurvived && rescued > best.creaturesRescued);
        if (newBest) {
            best.hoursSurvived = hrs;
            best.creaturesRescued = rescued;
            // forge-lint: disable-next-line(unsafe-typecast)
            best.settledAt = uint32(block.timestamp);
        }
        best.runsSettled += 1;
        emit RunSettled(player, hrs, rescued, newBest);
    }

    /// @notice The best-run record for `player` (`runsSettled == 0` means none yet).
    function bestRun(address player) external view returns (BestRun memory) {
        return _bestRun[player];
    }

    /// @notice The world as of `block.timestamp` WITHOUT writing (SPEC §5). The
    /// front end reads this to project the world between transactions; it must
    /// match what an UNPAID `sync` would persist for the same moment.
    /// @dev Projection is capped at the pinned-epoch edge — `preview` cannot show
    /// past the last covered epoch, where no seed exists yet (Ticket 4.5 §5.1).
    /// The third return, `cappedShort`, is true when the projection stopped before
    /// `block.timestamp` because the next epoch is not yet pinned. The reached
    /// game hour is already in `g.hoursElapsed`; repeating it as a `uint32` return
    /// would be redundant. When `cappedShort` is true, a paid `sync` or an `act`
    /// is needed to carry the world further (§5.2).
    function preview(address player)
        external
        view
        returns (Game memory g, Portal[MAX_OPEN_PORTALS] memory portals, bool cappedShort)
    {
        (g, portals,,,,,cappedShort) = _catchUpFree(player, _config, uint40(block.timestamp));
    }

    /// @dev Read `player`'s stored state and age it to `nowTs` via `TimeLib`,
    /// spawning only into epochs pinned to a word (Ticket 4.5). Pure projection —
    /// no writes, no events. `block.timestamp` fits `uint40` (year 36 812).
    /// @param oldWord Word pinning epochs below `storedCovered`.
    /// @param newWord Word pinning epochs at/above `storedCovered` (equal to
    ///   `oldWord` for a free, word-less call).
    /// @param storedCovered Split point (the player's stored `coveredEpochs`).
    /// @param maxCovered How far the world may advance: `storedCovered` for a free
    ///   call (stop at the pinned edge), `epochOf(nowTs)+1` on a reveal.
    function _catchUp(
        address player,
        Config memory c,
        uint256 oldWord,
        uint256 newWord,
        uint32 storedCovered,
        uint32 maxCovered,
        uint40 nowTs
    )
        internal
        view
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
        Game memory g = _players[player].game;
        Portal[MAX_OPEN_PORTALS] memory portals = _players[player].portals;
        return TimeLib.catchUp(g, portals, c, _portalTypeParams, oldWord, newWord, storedCovered, maxCovered, nowTs);
    }

    /// @dev The spawn epoch of timestamp `ts` for a game started at `startedAt`:
    /// `((ts - startedAt) / secPerHour) / epochHours`. Used to size the covered
    /// range after a reveal and to decide whether an action crosses the edge.
    function _epochOf(Config memory c, uint40 startedAt, uint40 ts) internal pure returns (uint32) {
        if (ts <= startedAt) return 0;
        return uint32(((uint256(ts) - uint256(startedAt)) / c.secPerHour) / c.epochHours);
    }

    /// @dev Convenience: a free (word-less) catch-up that stops at the pinned edge.
    /// Used by `sync` (unpaid), `settle`, `preview`, `canAct`, and the `startGame`
    /// auto-settle — none of which ever fetch a word.
    function _catchUpFree(address player, Config memory c, uint40 nowTs)
        internal
        view
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
        uint256 word = _players[player].epochWord;
        uint32 covered = _players[player].pending.coveredEpochs;
        return _catchUp(player, c, word, word, covered, covered, nowTs);
    }

    /// @dev Emit one `PortalCollapsed` per catch-up collapse, in order.
    function _emitCollapses(
        address player,
        TimeLib.Collapse[MAX_CATCHUP_EVENTS] memory collapses,
        uint8 count
    ) internal {
        for (uint8 i = 0; i < count; i++) {
            emit PortalCollapsed(
                player, collapses[i].slot, collapses[i].deaths, collapses[i].hpLost, collapses[i].atHour
            );
        }
    }

    /// @dev Emit one `PortalSpawned` per catch-up spawn, in order.
    function _emitSpawns(address player, TimeLib.Spawn[MAX_CATCHUP_EVENTS] memory spawns, uint8 count) internal {
        for (uint8 i = 0; i < count; i++) {
            emit PortalSpawned(player, spawns[i].slot, spawns[i].portalType, spawns[i].nameIndex, spawns[i].atHour);
        }
    }

    /// @notice The full immutable configuration. The front end reads parameters
    /// from here rather than hardcoding them (CLAUDE.md rule).
    function config() external view returns (Config memory) {
        return _config;
    }

    /// @notice Parameters for a single portal type.
    function portalTypeParams(PortalType portalType) external view returns (PortalTypeParams memory) {
        return _portalTypeParams[uint256(uint8(portalType))];
    }

    /// @notice Compute the risk score and level for the given portal fields.
    /// @dev A thin wrapper over `RiskLib` so anyone can verify the contract's
    /// risk maths directly, and so ticket 1.3 can cross-check the TS mirror
    /// against on-chain output. `lives` is creatures + observer + rescuer.
    function riskScore(uint8 stability, uint8 energy, uint16 hoursToCollapse, uint8 lives)
        external
        pure
        returns (uint8 score, RiskLevel level)
    {
        score = RiskLib.score(stability, energy, hoursToCollapse, lives);
        level = RiskLib.levelOf(score);
    }

    /// @notice The full game state for `player` (`startedAt == 0` means none).
    function getGame(address player) external view returns (Game memory) {
        return _players[player].game;
    }

    /// @notice The full portal array for `player`.
    function getPortals(address player) external view returns (Portal[MAX_OPEN_PORTALS] memory) {
        return _players[player].portals;
    }

    /// @notice The deferred (two-phase) action for `player`, if any (`active ==
    /// false` means none). The front end reads this to know a survey is in flight
    /// and to recover the `requestId` (SPEC §6.3).
    function getPending(address player) external view returns (Pending memory) {
        return _players[player].pending;
    }

    /// @notice The randomness source address. The front end reads it (rather than
    /// hardcoding) and it is the only address allowed to call `receiveWord`.
    function randomSource() external view returns (IRandomSource) {
        return _randomSource;
    }

    /// @notice Check whether `action` is allowed on `slot` for `player` as of
    /// `block.timestamp`. Returns `Refusal.None` (0) if allowed, or the first
    /// applicable refusal code otherwise.
    ///
    /// @dev Computed on the AGED state (the same projection `preview` returns),
    /// so it agrees with what `act` would do this block: a portal that has
    /// collapsed reads as `Empty`, a game that died while away reads as
    /// `GameNotActive`.
    ///
    /// When `slot >= MAX_OPEN_PORTALS` the portal is left empty; the check
    /// returns `InvalidSlot` for any active game.
    function canAct(address player, uint8 slot, Action action) external view returns (Refusal) {
        Config memory c = _config;
        (Game memory g, Portal[MAX_OPEN_PORTALS] memory portals,,,,,) =
            _catchUpFree(player, c, uint40(block.timestamp));
        Portal memory p;
        if (slot < MAX_OPEN_PORTALS) {
            p = portals[slot];
        }
        return RulesLib.check(g, p, c, slot, action);
    }
}
