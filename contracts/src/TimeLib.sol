// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Game,
    Portal,
    Config,
    PortalTypeParams,
    PortalType,
    PortalStatus,
    MAX_OPEN_PORTALS,
    MAX_RESCUERS,
    MAX_CATCHUP_EVENTS,
    SPAWN_DEBT_MAX,
    NAME_POOL_SIZE,
    rescuerReadyAt,
    setRescuerReadyAt
} from "./PortalLabTypes.sol";

/// @title TimeLib — lazy time: age the world to `now` by formula (SPEC §5, §7).
/// @notice Pure, stateless library. The contract is not executed between
/// transactions, so the world ages RETROACTIVELY: on any access the state is
/// brought forward to the current moment by walking the EVENTS of the window
/// (collapses and births), never its hours.
///
/// A library cannot emit events, so `catchUp` returns the list of collapses and
/// the list of births that happened; the contract emits them.
///
/// @dev THE WORLD DOES NOT DEPEND ON WHEN ANYONE CALLS. A portal is born at the
/// hour its pressure matures (and a slot is free), not at the hour of the call
/// that happens to age the world. Every event hour is a function of the stored
/// snapshot and of time alone, so one catch-up to `c` leaves exactly the state
/// that a catch-up to `b` followed by one to `c` leaves, for any `b` in between.
/// `sync` is free and open to anyone; this property is what makes that harmless.
///
/// HARD REQUIREMENT: there must be NO loop whose iteration count depends on the
/// elapsed hours, under ANY circumstances. A per-hour loop would not fit in a
/// block after only a few minutes of absence, and — more importantly — the front
/// end could not reproduce it locally, whereas it can reproduce a formula. Every
/// loop here is bounded by MAX_OPEN_PORTALS (12), MAX_RESCUERS (4), the
/// binary-search cap (64) or the event fuse MAX_CATCHUP_EVENTS (64).
///
/// Everything is computed in the GAME-HOUR domain. The game hour of a timestamp
/// `t` is `h(t) = (t - startedAt) / secPerHour` (truncated). All intervals are
/// taken as DIFFERENCES of `h(...)`, never as timestamp differences divided
/// separately: otherwise the per-segment truncation would drift away from the
/// total hour count. A portal's collapse hour is
/// `h(snapshotAt) + hoursToCollapse`, which is exactly `h(collapseAt)` because
/// `hoursToCollapse` is integral; using it keeps ageing and collapse detection
/// consistent, so re-snapshotting a survivor preserves its collapse moment (no
/// drift, `preview` always equals `sync`).
library TimeLib {
    /// @dev Salts that keep a spawned portal's draws (type / hours / name)
    /// uncorrelated within one roll. Survey (EffectsLib) uses 0/1/2; these differ
    /// for clarity, though the per-portal `rngNonce` already separates rolls.
    uint8 private constant SALT_TYPE = 3;
    uint8 private constant SALT_HOURS = 4;
    uint8 private constant SALT_NAME = 5;

    /// @dev "No such hour": an empty slot's collapse hour, or no birth pending.
    uint256 private constant NONE = type(uint256).max;

    /// @dev Domain tag that separates the epoch-seed derivation from the survey's
    /// per-parameter draws. The survey (`EffectsLib._fromWord`) hashes
    /// `abi.encode(word, uint8 salt)`; Ticket 4.5 §3.2 warns that one delivered
    /// word can now feed BOTH the epoch spawns and a survey in the SAME reveal, so
    /// the two derivations must never collide. A string tag reshapes the
    /// abi.encode layout irreversibly — unlike a salt offset, which a later edit
    /// could slide back into the survey's 0/1/2 range. See `epochSeed`.
    string private constant EPOCH_DOMAIN = "portal-lab/spawn-epoch";

    /// @notice Seed pinned to spawn `epoch`, derived from `word`. Exposed
    /// `internal` so tests can prove it never equals a survey draw (§3.3/§6.1).
    /// @dev `keccak256(abi.encode(EPOCH_DOMAIN, word, epoch))` — the domain tag is
    /// the first encoded element, so the byte layout can never coincide with the
    /// survey's two-element `abi.encode(word, salt)`.
    function epochSeed(uint256 word, uint256 epoch) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(EPOCH_DOMAIN, word, epoch)));
    }

    /// @dev One spawn sub-draw: the epoch seed, the spawn's own id (unique and
    /// monotonic, so two spawns in one epoch differ) and a salt (type / hours /
    /// name kept uncorrelated). The randomness lives in the word via `epochSeed`;
    /// the id is only a discriminator (Ticket 4.5 §3.1).
    function _spawnDraw(uint256 seed, uint32 spawnId, uint8 salt) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, spawnId, salt)));
    }

    /// @dev Which word pins `epoch`: the OLD stored word for epochs already pinned
    /// (`epoch < splitCoveredEpochs`), the NEW delivered word beyond that (Ticket
    /// 4.5 §2.3). The split is `== storedCoveredEpochs` so an epoch is pinned ONCE,
    /// to whatever word was current when the world first entered it; the past is
    /// never recomputed.
    function _wordFor(uint256 epoch, uint256 oldWord, uint256 newWord, uint256 splitCoveredEpochs)
        private
        pure
        returns (uint256)
    {
        return epoch < splitCoveredEpochs ? oldWord : newWord;
    }

    /// @notice One portal collapse that happened during catch-up.
    struct Collapse {
        uint8 slot;
        uint8 deaths;
        uint16 hpLost;
        uint32 atHour;
    }

    /// @notice One portal that appeared during catch-up.
    struct Spawn {
        uint8 slot;
        PortalType portalType;
        uint16 nameIndex;
        uint32 atHour;
    }

    /// @dev Working state of one walk, kept in memory so the helpers share it
    /// without a stack of a dozen locals.
    struct Walk {
        uint256 sph; // seconds per game hour
        uint256 h0; // window start: h(lastTickAt)
        uint256 hEnd; // last hour the world may reach: hNow, or the pinned edge
        uint256 hNow; // h(nowTs)
        uint256 debt0; // stored spawnDebt at the window start
        uint256 aEnd; // A(hEnd): the pressure available at the end of the walk
        uint256 cursor; // the walk has lived up to this hour
        uint256 births; // portals born in this window
        uint256 nextMature; // hour the (births+1)-th portal's pressure matures (NONE: not by hEnd)
        uint256 openCount; // portals open at `cursor`
        uint256 yieldSum; // their power yield per hour
        uint256 nEv; // events processed (collapses + births)
        uint256 nCol; // collapse records written
        uint256 nSp; // birth records written
        uint8 colSlot; // slot of the next collapse
        uint256 colNext; // its hour (NONE: no portal open)
        bool birthsOk; // births allowed: a portal costs pressure and [h0, hEnd] is pinned
        bool died;
        uint256 deathHour;
        uint256 oldWord;
        uint256 newWord;
        uint256 split; // storedCoveredEpochs
        uint256 seedEpoch; // epoch whose seed is cached in `seed` (NONE: nothing cached)
        uint256 seed;
    }

    /// @notice Bring `g` and `portals` forward to `nowTs`, birthing only into
    /// epochs pinned to a word (Ticket 4.5).
    /// @dev The rule (SPEC §5.3, §7). Pressure available at hour `h` is
    /// `A(h) = debt0 + spawnPressure(h0, h)`. The k-th birth of the window happens
    /// at the smallest hour, not before the previous event, at which
    /// `A(h) >= k * spawnCostUnits` and a slot is free — a matured birth into a
    /// full lab waits for the first collapse that frees a slot. Collapses (of
    /// stored portals and of portals born in this window) and births are walked in
    /// one chronological pass; at an equal hour collapses come first, in ascending
    /// slot order, then births. Between events: power regen plus the yield of the
    /// open portals (capped at `powerMax`), and the overflow drain while exactly
    /// twelve are open, with death inside the segment.
    /// @param g Stored game.
    /// @param portals Stored portal array (12 slots).
    /// @param c Immutable configuration.
    /// @param types Per-type parameters, indexed by `PortalType`.
    /// @param oldWord Word pinning epochs `< storedCoveredEpochs`.
    /// @param newWord Word pinning epochs `>= storedCoveredEpochs` (equal to
    ///   `oldWord` for a free, word-less call; the freshly delivered word on a
    ///   reveal).
    /// @param storedCoveredEpochs Split point: epochs below it use `oldWord`,
    ///   at or above use `newWord` (§2.3). `0` means no epoch pinned yet.
    /// @param maxCoveredEpochs The world may advance only INTO epochs below this
    ///   (births need their epoch pinned). Free calls pass `storedCoveredEpochs`
    ///   (stop at the pinned edge); a reveal passes the epoch of `nowTs` plus one
    ///   (advance all the way). The deterministic overflow death beyond the edge
    ///   (§5.5) ignores this cap — it needs no word.
    /// @param nowTs Current `block.timestamp`. A clock behind `lastTickAt` by a
    ///   game hour or more is not a moment the world can be brought to and reverts
    ///   (checked arithmetic, Panic 0x11).
    /// @return The aged game, the aged portals, the collapse events (valid for
    ///   indices `0..collapseCount-1`) and their count, the birth events (valid
    ///   for `0..spawnCount-1`) and their count, and `cappedShort` — true when the
    ///   world could NOT reach `nowTs` (the next epoch is not pinned, or the event
    ///   fuse blew). The caller reads it to decide whether a word must be fetched
    ///   (§4.1); on a run that died in this call it carries no meaning, and every
    ///   caller checks `finished` first.
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
        internal
        pure
        returns (
            Game memory,
            Portal[MAX_OPEN_PORTALS] memory,
            Collapse[MAX_CATCHUP_EVENTS] memory events,
            uint8 eventCount,
            Spawn[MAX_CATCHUP_EVENTS] memory spawns,
            uint8 spawnCount,
            bool cappedShort
        )
    {
        // 1. No game, already finished, or clock before game start: nothing to
        //    age. (`nowTs < startedAt` cannot happen on-chain, where startGame
        //    stamps startedAt = block.timestamp; the guard keeps the maths from
        //    underflowing on fabricated inputs.)
        if (g.startedAt == 0 || g.finished || nowTs < g.startedAt) {
            return (g, portals, events, 0, spawns, 0, false);
        }

        Walk memory w;
        w.sph = c.secPerHour;
        w.hNow = (uint256(nowTs) - uint256(g.startedAt)) / w.sph;
        w.h0 = (uint256(g.lastTickAt) - uint256(g.startedAt)) / w.sph; // == g.hoursElapsed
        w.cursor = w.h0;
        w.debt0 = uint256(g.spawnDebt);
        w.oldWord = oldWord;
        w.newWord = newWord;
        w.split = storedCoveredEpochs;
        w.seedEpoch = NONE;

        // How far the world may be walked: only through epochs pinned to a word
        // (epoch e is pinned iff e < maxCoveredEpochs). With nothing pinned the
        // world stays where it is. Births are allowed only when every hour of
        // [h0, hEnd] lies in a pinned epoch, and only when a portal costs pressure
        // (a free portal would be born without end; deploy forbids it).
        uint256 edge = maxCoveredEpochs == 0 ? w.h0 : uint256(maxCoveredEpochs) * uint256(c.epochHours) - 1;
        w.birthsOk = maxCoveredEpochs > 0 && w.h0 <= edge && c.spawnCostUnits > 0;
        uint256 room = edge > w.h0 ? edge - w.h0 : 0;
        uint256 ahead = w.hNow - w.h0; // reverts on a stale clock, see @param nowTs
        w.hEnd = w.h0 + (ahead < room ? ahead : room);
        cappedShort = w.hEnd < w.hNow;
        w.aEnd = w.debt0 + spawnPressure(w.h0, w.hEnd, c);

        // 2. Collapse hour of every occupied slot, the open count and the yield.
        uint256[MAX_OPEN_PORTALS] memory colHour;
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (portals[i].status == PortalStatus.Empty) {
                colHour[i] = NONE;
                continue;
            }
            w.openCount += 1;
            w.yieldSum += uint256(types[uint8(portals[i].portalType)].powerYieldPerHour);
            // collapse hour == h(snapshotAt) + hoursToCollapse == h(collapseAt).
            colHour[i] = (uint256(portals[i].snapshotAt) - uint256(g.startedAt)) / w.sph
                + uint256(portals[i].hoursToCollapse);
        }
        _findNextCollapse(colHour, w);

        // 3. One chronological pass over the events. O(events), never O(hours).
        //    The next birth happens at max(cursor, maturity hour) while a slot is
        //    free; the maturity hour changes only when a birth is made, so it is
        //    searched once per birth, not once per event; likewise the next
        //    collapse is re-found only when the set of open portals changes.
        w.nextMature = w.birthsOk ? _matureHour(w, c, w.h0) : NONE;
        bool fuse = _walk(g, portals, colHour, w, c, types, events, spawns);
        // The last segment, to the end of the window. After a blown fuse the walk
        // stops at the hour of the last processed event instead.
        if (!w.died && !fuse) _advance(g, w, c, w.hEnd);
        if (fuse) cappedShort = true;
        uint256 hStop = fuse ? w.cursor : w.hEnd;

        // 4. Beyond the pinned edge (§5.5): the world cannot be walked there (no
        //    word, so no births), but the abandoned-lab overflow needs no word. From
        //    the state at hEnd, find the hour the remaining pressure would fill the
        //    lab; if the ensuing overflow is lethal by hNow, the run ends then. No
        //    portal is created in the tail. As before, a lab already full at the
        //    edge is not considered (the rule fills a lab, it does not drain a full
        //    one). Not applied after a blown fuse: there the next call simply
        //    continues the walk.
        bool tailDeath = false;
        if (!w.died && !fuse && cappedShort && c.hpOverflowPerHour > 0 && w.openCount < MAX_OPEN_PORTALS) {
            uint256 debtE = w.aEnd - w.births * uint256(c.spawnCostUnits);
            uint256 needed = (MAX_OPEN_PORTALS - w.openCount) * uint256(c.spawnCostUnits);
            if (debtE + spawnPressure(w.hEnd, w.hNow, c) >= needed) {
                uint256 hFill = _firstHour(w.hEnd, w.hEnd, w.hNow, debtE, needed, c);
                uint256 ov = uint256(c.hpOverflowPerHour);
                uint256 dh = hFill + (uint256(g.hp) + ov - 1) / ov; // + ceil(hp / ov)
                if (dh <= w.hNow) {
                    w.died = true;
                    w.deathHour = dh;
                    tailDeath = true;
                }
            }
        }

        // 5. Commit. `hFreeze` is the hour the stored world is stamped at; spawn
        //    debt is the pressure available then, less what the births spent.
        uint256 hFreeze;
        uint40 effTs;
        if (w.died) {
            // A walk death freezes the world at the death hour (never behind the
            // window start, which only an overdue fabricated snapshot could cause);
            // a tail death freezes it at the edge it never got past.
            hFreeze = tailDeath ? w.hEnd : (w.deathHour > w.h0 ? w.deathHour : w.h0);
            effTs = uint40(uint256(g.startedAt) + hFreeze * w.sph);
            g.hp = 0;
            g.finished = true;
            g.diedAtHour = uint32(w.deathHour);
            g.hoursElapsed = uint32(w.deathHour);
            // The clock of a finished game stops at its death, whoever looks later.
            g.lastTickAt = uint40(uint256(g.startedAt) + w.deathHour * w.sph);
        } else {
            hFreeze = hStop;
            // A world that could not reach `nowTs` is stamped at the hour it
            // stopped, NOT `nowTs`, so the next call resumes from there.
            effTs = cappedShort ? uint40(uint256(g.startedAt) + hStop * w.sph) : nowTs;
            g.hoursElapsed = uint32(hStop);
            g.lastTickAt = effTs;
        }
        uint256 debtOut = _available(w, c, hFreeze) - w.births * uint256(c.spawnCostUnits);
        g.spawnDebt = debtOut > SPAWN_DEBT_MAX ? uint32(SPAWN_DEBT_MAX) : uint32(debtOut);
        g.openPortals = uint8(w.openCount);

        // Release rescuers whose recovery cooldown has matured by the stamped hour
        // (SPEC §4.3). A COMPARISON against that hour, never a per-hour loop.
        // `rescuersFree` is capped at `rescuersTotal`: a matured cell can only ever
        // return a rescuer that a blind miss removed, so the count is
        // self-balancing, but the cap defends a malformed snapshot overshooting.
        for (uint8 i = 0; i < MAX_RESCUERS; i++) {
            uint32 readyAt = rescuerReadyAt(g, i);
            if (readyAt != 0 && uint256(readyAt) <= hFreeze) {
                setRescuerReadyAt(g, i, 0);
                if (g.rescuersFree < c.rescuersTotal) g.rescuersFree += 1;
            }
        }

        _ageAll(g, portals, c, types, w.sph, hFreeze, effTs);

        return (g, portals, events, uint8(w.nCol), spawns, uint8(w.nSp), cappedShort);
    }

    /// @dev The event loop of step 3: collapses and births in chronological
    /// order until the window is exhausted, the run dies, or the fuse blows.
    /// Returns true when the fuse stopped it. Kept out of `catchUp` so neither
    /// frame runs out of stack.
    function _walk(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        uint256[MAX_OPEN_PORTALS] memory colHour,
        Walk memory w,
        Config memory c,
        PortalTypeParams[5] memory types,
        Collapse[MAX_CATCHUP_EVENTS] memory events,
        Spawn[MAX_CATCHUP_EVENTS] memory spawns
    ) private pure returns (bool fuse) {
        while (true) {
            uint256 ch = w.colNext;
            uint256 bh = NONE;
            if (w.nextMature != NONE && w.openCount < MAX_OPEN_PORTALS) {
                bh = w.nextMature > w.cursor ? w.nextMature : w.cursor;
            }
            // At an equal hour the collapse goes first (`ch <= bh`).
            bool isCollapse = ch <= w.hEnd && ch <= bh;
            if (!isCollapse && bh > w.hEnd) return false; // nothing more inside the window
            if (w.nEv == MAX_CATCHUP_EVENTS) return true;
            _advance(g, w, c, isCollapse ? ch : bh);
            if (w.died) return false;
            if (isCollapse) {
                _collapse(g, portals, colHour, w, c, types, events, w.colSlot, ch);
                if (w.died) return false;
            } else {
                _birth(g, portals, colHour, w, c, types, spawns, bh);
                w.nextMature = _matureHour(w, c, w.nextMature);
            }
            w.nEv += 1;
        }
    }
    /// @notice Spawn pressure accrued over game hours `[a, b)` (b exclusive).
    /// @dev CLOSED-FORM sum of the arithmetic progression `base + ramp*h`:
    ///   sum_{h=a}^{b-1} (base + ramp*h)
    ///     = base*(b - a) + ramp * ((a + b - 1) * (b - a)) / 2
    /// There is deliberately NO per-hour loop here (SPEC §4.6/§7): a loop would
    /// not fit in a block over a long pause and the front end could not reproduce
    /// it, whereas it can reproduce this formula. `(a + b - 1) * (b - a)` is
    /// always even (it is twice a triangular number), so the `/2` is exact.
    /// Computed in `uint256`; the caller saturates the result into `spawnDebt`.
    function spawnPressure(uint256 a, uint256 b, Config memory c) internal pure returns (uint256) {
        if (b <= a) return 0;
        uint256 n = b - a;
        uint256 tri = ((a + b - 1) * n) / 2;
        return uint256(c.basePressurePerHour) * n + uint256(c.pressureRampPerHour) * tri;
    }

    /// @dev `A(h) = debt0 + spawnPressure(h0, h)`: the pressure available at hour
    /// `h` of the window, before births spend any of it. Not saturated.
    function _available(Walk memory w, Config memory c, uint256 h) private pure returns (uint256) {
        return w.debt0 + spawnPressure(w.h0, h, c);
    }

    /// @dev Smallest hour `h` in `[lo, hi]` with `have + spawnPressure(from, h) >=
    /// target`. The caller guarantees the predicate holds at `hi`, and pressure
    /// never decreases with `h`, so the answer exists.
    ///
    /// No per-hour scan. Every hour at or after `lo` adds at least the pressure of
    /// hour `lo` itself, `r = basePressurePerHour + pressureRampPerHour * lo`, so the
    /// answer lies within `ceil(shortfall / r)` hours of `lo`. With a flat rate that
    /// estimate IS the answer, and with the deployed ramp (1 unit per hour against
    /// 1000) it nearly always is: one evaluation at the hour before confirms it.
    /// Otherwise a BINARY SEARCH capped at 64 iterations finishes the job. This was
    /// chosen over an integer square root of the quadratic closed form: it costs
    /// about two pressure evaluations per birth and needs no rounding correction.
    function _firstHour(uint256 from, uint256 lo, uint256 hi, uint256 have, uint256 target, Config memory c)
        private
        pure
        returns (uint256)
    {
        uint256 atLo = have + spawnPressure(from, lo, c);
        if (atLo >= target) return lo;
        uint256 r = uint256(c.basePressurePerHour) + uint256(c.pressureRampPerHour) * lo;
        if (r > 0) {
            uint256 cap = lo + (target - atLo + r - 1) / r;
            if (cap < hi) hi = cap;
        }
        // Invariant: the predicate fails at lo and holds at hi.
        if (hi - lo > 1 && have + spawnPressure(from, hi - 1, c) < target) return hi;
        for (uint256 it = 0; it < 64 && hi - lo > 1; it++) {
            uint256 mid = (lo + hi) / 2;
            if (have + spawnPressure(from, mid, c) >= target) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        return hi;
    }
    /// @dev Maturity hour of the next birth — the smallest hour `h` with
    /// `A(h) >= (births + 1) * spawnCostUnits` — or NONE if it does not mature by
    /// `hEnd`. `from` is a lower bound already known (the previous maturity hour:
    /// targets only grow and `A` never decreases).
    function _matureHour(Walk memory w, Config memory c, uint256 from) private pure returns (uint256) {
        uint256 target = (w.births + 1) * uint256(c.spawnCostUnits);
        if (w.aEnd < target) return NONE;
        return _firstHour(w.h0, from, w.hEnd, w.debt0, target, c);
    }

    /// @dev Find the earliest collapse among the occupied slots into
    /// `w.colSlot` / `w.colNext`; ties go to the lower slot. NONE when every slot
    /// is empty.
    function _findNextCollapse(uint256[MAX_OPEN_PORTALS] memory colHour, Walk memory w) private pure {
        uint256 hour = NONE;
        uint256 slot = 0;
        for (uint256 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (colHour[i] < hour) {
                hour = colHour[i];
                slot = i;
            }
        }
        w.colSlot = uint8(slot);
        w.colNext = hour;
    }

    /// @dev Live the segment `cursor -> to`: power regen plus the open portals'
    /// yield (capped at powerMax), and the overflow drain while exactly twelve
    /// are open — with death inside the segment, at `cursor + ceil(hp / drain)`.
    function _advance(Game memory g, Walk memory w, Config memory c, uint256 to) private pure {
        if (to <= w.cursor) return;
        uint256 delta = to - w.cursor;

        uint256 np = uint256(g.power) + (uint256(c.powerRegenPerHour) + w.yieldSum) * delta;
        g.power = np > c.powerMax ? c.powerMax : uint16(np);

        if (w.openCount == MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0) {
            uint256 ov = uint256(c.hpOverflowPerHour);
            uint256 hToDeath = (uint256(g.hp) + ov - 1) / ov; // ceil(hp / ov)
            if (hToDeath <= delta) {
                w.died = true;
                w.deathHour = w.cursor + hToDeath;
                w.cursor = w.deathHour;
                g.hp = 0;
                return;
            }
            // hToDeath > delta ⇒ ov*delta < hp, so no underflow.
            g.hp = uint16(uint256(g.hp) - ov * delta);
        }
        w.cursor = to;
    }

    /// @dev Collapse the portal in slot `s` at hour `ch`.
    function _collapse(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        uint256[MAX_OPEN_PORTALS] memory colHour,
        Walk memory w,
        Config memory c,
        PortalTypeParams[5] memory types,
        Collapse[MAX_CATCHUP_EVENTS] memory events,
        uint8 s,
        uint256 ch
    ) private pure {
        // Read all needed fields BEFORE zeroing the slot.
        uint256 deaths = portals[s].creaturesKnown
            ? uint256(portals[s].creatures)
            : (uint256(portals[s].creaturesLo) + uint256(portals[s].creaturesHi)) / 2;
        if (portals[s].observerInside) deaths += 1;
        if (portals[s].rescuerInside) deaths += 1;

        // An empty collapse still costs hpEmptyCollapse — it is the keeper's
        // failure, unlike closing an empty portal (free, §4.4).
        uint256 hpLost = deaths > 0
            ? uint256(c.hpCollapseBase) + uint256(c.hpCollapsePerDeath) * deaths
            : uint256(c.hpEmptyCollapse);
        uint256 hpBefore = uint256(g.hp);
        uint256 actualLost = hpBefore > hpLost ? hpLost : hpBefore; // min(loss, hp before the hit)

        // Filled in place: the return array already holds a zeroed record per index.
        Collapse memory rec = events[w.nCol];
        rec.slot = s;
        rec.deaths = uint8(deaths);
        rec.hpLost = uint16(actualLost);
        rec.atHour = uint32(ch);
        w.nCol += 1;
        g.hp = uint16(hpBefore - actualLost);

        // Crew inside dies and does NOT return to the pool (§4.3).
        // The slot is freed: a fresh zeroed portal (status == Empty).
        w.yieldSum -= uint256(types[uint8(portals[s].portalType)].powerYieldPerHour);
        Portal memory blank;
        portals[s] = blank;
        colHour[s] = NONE;
        w.openCount -= 1;
        _findNextCollapse(colHour, w);

        if (g.hp == 0) {
            w.died = true;
            w.deathHour = ch;
        }
    }

    /// @dev Birth of one portal at hour `b` into the first free slot. The moment
    /// is deterministic; only the CONTENTS are random (SPEC §7), drawn from the
    /// seed of the birth hour's epoch, `epochSeed(wordFor(epoch), epoch)` with
    /// `epoch = b / epochHours`. The player cannot pre-compute the word of a
    /// future epoch, so they cannot schedule their run beyond the current epoch
    /// (§6.8). `rngNonce` is still bumped per portal — it no longer feeds the
    /// spawn draw, but keeping the bump preserves the nonce stream the blind-rescue
    /// stub reads. Ranges are the type ranges verbatim — exact energy / stability /
    /// creatures are born at survey (SPEC §6). Names are not stored on-chain,
    /// only `nameIndex` (SPEC §7). From `b` on the newborn is an ordinary open
    /// portal: it yields power, counts toward twelve and can collapse.
    function _birth(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        uint256[MAX_OPEN_PORTALS] memory colHour,
        Walk memory w,
        Config memory c,
        PortalTypeParams[5] memory types,
        Spawn[MAX_CATCHUP_EVENTS] memory spawns,
        uint256 b
    ) private pure {
        uint8 slot = 0;
        while (portals[slot].status != PortalStatus.Empty) slot++; // a slot is free: openCount < 12

        uint256 epoch = b / uint256(c.epochHours);
        if (epoch != w.seedEpoch) {
            w.seed = epochSeed(_wordFor(epoch, w.oldWord, w.newWord, w.split), epoch);
            w.seedEpoch = epoch;
        }

        g.rngNonce += 1; // vestigial for spawns; preserves the blind-rescue nonce stream
        g.spawnCount += 1;
        uint32 spawnId = g.spawnCount; // discriminator: unique per spawn within the epoch

        PortalType pt = PortalType(uint8(_spawnDraw(w.seed, spawnId, SALT_TYPE) % 5));
        PortalTypeParams memory tp = types[uint256(uint8(pt))];

        // Exact, always-public collapse time inside the type's range. Computed
        // inline because the range can exceed 255 and RandomStub.inRange is
        // uint8-only.
        uint256 span = uint256(tp.hoursMax) - uint256(tp.hoursMin) + 1;
        uint16 htc = uint16(uint256(tp.hoursMin) + (_spawnDraw(w.seed, spawnId, SALT_HOURS) % span));
        uint16 nameIndex = uint16(_spawnDraw(w.seed, spawnId, SALT_NAME) % NAME_POOL_SIZE);

        Portal memory np; // built fresh, never by copy (CLAUDE.md rule)
        np.id = uint16(spawnId);
        np.portalType = pt;
        np.nameIndex = nameIndex;
        np.status = PortalStatus.Open;
        // surveyed / surveyPending / crew / exact fields stay at their zeroed
        // defaults: the portal is unsurveyed and empty of people.
        np.hoursToCollapse = htc;
        np.spawnedAtHour = uint32(b);
        np.snapshotAt = uint40(uint256(g.startedAt) + b * w.sph);
        np.energyLo = tp.energyMin;
        np.energyHi = tp.energyMax;
        np.stabilityLo = tp.stabilityMin;
        np.stabilityHi = tp.stabilityMax;
        np.creaturesLo = tp.creaturesMin;
        np.creaturesHi = tp.creaturesMax;
        portals[slot] = np;

        uint256 ch = b + uint256(htc);
        colHour[slot] = ch;
        if (ch < w.colNext || (ch == w.colNext && slot < w.colSlot)) {
            w.colSlot = slot;
            w.colNext = ch;
        }
        w.openCount += 1;
        w.yieldSum += uint256(tp.powerYieldPerHour);
        w.births += 1;

        Spawn memory rec = spawns[w.nSp]; // filled in place, like the collapse records
        rec.slot = slot;
        rec.portalType = pt;
        rec.nameIndex = nameIndex;
        rec.atHour = uint32(b);
        w.nSp += 1;
    }

    /// @dev Age every open portal to hour `hTo` and re-snapshot it at `stampTs`
    /// (whose game hour is `hTo`): `e = hTo - h(snapshotAt)`. Ageing composes —
    /// two steps of `e1` and `e2` equal one of `e1 + e2` — which is what keeps a
    /// split catch-up equal to a single one.
    function _ageAll(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        PortalTypeParams[5] memory types,
        uint256 sph,
        uint256 hTo,
        uint40 stampTs
    ) private pure {
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (portals[i].status == PortalStatus.Empty) continue;
            uint256 hSnap = (uint256(portals[i].snapshotAt) - uint256(g.startedAt)) / sph;
            uint256 e = hTo - hSnap; // survivors have hoursToCollapse >= e
            if (portals[i].surveyed) {
                uint256 deg = uint256(types[uint8(portals[i].portalType)].degradePerHour) * e;
                portals[i].stability = uint256(portals[i].stability) > deg
                    ? uint8(uint256(portals[i].stability) - deg)
                    : 0;
            } else {
                // Unsurveyed: knowledge decays — the energy and stability
                // ranges drift outward by rangeWidenPerHour on each bound per
                // game hour (SPEC §3.1, Decision 3). The CREATURES range is
                // deliberately left untouched: an ever-widening creature count
                // would inflate the blind-close penalty without bound, and the
                // number of inhabitants is set by the portal's nature, not by
                // how stale the observation is.
                uint256 widen = uint256(c.rangeWidenPerHour) * e;
                portals[i].energyLo =
                    uint256(portals[i].energyLo) > widen ? uint8(uint256(portals[i].energyLo) - widen) : 0;
                uint256 eHi = uint256(portals[i].energyHi) + widen;
                portals[i].energyHi = eHi > 100 ? 100 : uint8(eHi);
                portals[i].stabilityLo =
                    uint256(portals[i].stabilityLo) > widen ? uint8(uint256(portals[i].stabilityLo) - widen) : 0;
                uint256 sHi = uint256(portals[i].stabilityHi) + widen;
                portals[i].stabilityHi = sHi > 100 ? 100 : uint8(sHi);
            }
            portals[i].hoursToCollapse =
                uint256(portals[i].hoursToCollapse) > e ? uint16(uint256(portals[i].hoursToCollapse) - e) : 0;
            portals[i].snapshotAt = stampTs;
        }
    }
}
