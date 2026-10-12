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
    SPAWN_DEBT_MAX,
    NAME_POOL_SIZE,
    rescuerReadyAt,
    setRescuerReadyAt
} from "./PortalLabTypes.sol";

/// @title TimeLib — lazy time: age the world to `now` by formula (SPEC §5, §7).
/// @notice Pure, stateless library. The contract is not executed between
/// transactions, so the world ages RETROACTIVELY: on any access the state is
/// brought forward to the current moment with a formula whose cost is
/// O(number of portals) — never O(elapsed hours).
///
/// A library cannot emit events, so `catchUp` returns the list of collapses and
/// the list of spawns that happened; the contract emits them.
///
/// @dev HARD REQUIREMENT: there must be NO loop whose iteration count depends on
/// the elapsed hours, under ANY circumstances. A per-hour loop would not fit in a
/// block after only a few minutes of absence, and — more importantly — the front
/// end could not reproduce it locally, whereas it can reproduce a formula. Every
/// loop here is bounded by MAX_OPEN_PORTALS (12) or by the binary-search cap (64).
///
/// Everything is computed in the GAME-HOUR domain. The game hour of a timestamp
/// `t` is `h(t) = (t - startedAt) / secPerHour` (truncated). All intervals are
/// taken as DIFFERENCES of `h(...)`, never as timestamp differences divided
/// separately: otherwise the per-segment truncation would drift away from the
/// total hour count. A portal's collapse hour is
/// `h(snapshotAt) + hoursToCollapse`, which is exactly `h(collapseAt)` because
/// `hoursToCollapse` is integral; using it keeps ageing and collapse detection
/// consistent, so re-snapshotting a survivor to `nowTs` preserves its collapse
/// moment (no drift, `preview` always equals `sync`).
library TimeLib {
    /// @dev Salts that keep a spawned portal's draws (type / hours / name)
    /// uncorrelated within one roll. Survey (EffectsLib) uses 0/1/2; these differ
    /// for clarity, though the per-portal `rngNonce` already separates rolls.
    uint8 private constant SALT_TYPE = 3;
    uint8 private constant SALT_HOURS = 4;
    uint8 private constant SALT_NAME = 5;

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

    /// @notice Bring `g` and `portals` forward to `nowTs`, spawning only into
    /// epochs pinned to a word (Ticket 4.5).
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
    ///   (random spawns need their epoch pinned). Free calls pass
    ///   `storedCoveredEpochs` (stop at the pinned edge); a reveal passes the
    ///   epoch of `nowTs` plus one (advance all the way). The deterministic
    ///   long-absence death (§5.5) ignores this cap — it needs no word.
    /// @param nowTs Current `block.timestamp`.
    /// @return The aged game, the aged portals, the collapse events (valid for
    ///   indices `0..collapseCount-1`) and their count, the spawn events (valid
    ///   for `0..spawnCount-1`) and their count, and `cappedShort` — true when the
    ///   world could NOT reach `nowTs` because that would need an unpinned epoch
    ///   (and the game did not end). The caller reads it to decide whether a word
    ///   must be fetched (§4.1).
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
            Collapse[MAX_OPEN_PORTALS] memory events,
            uint8 eventCount,
            Spawn[MAX_OPEN_PORTALS] memory spawns,
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

        uint256 sph = c.secPerHour;
        uint256 eph = c.epochHours;
        uint256 hNow = (uint256(nowTs) - uint256(g.startedAt)) / sph;
        uint256 cursor = (uint256(g.lastTickAt) - uint256(g.startedAt)) / sph; // == g.hoursElapsed
        uint256 windowStart = cursor; // saved: the walk mutates `cursor`

        // How far the world may be aged for RANDOM spawns: only into epochs that
        // are pinned to a word. Epoch e is advanceable iff e < maxCoveredEpochs,
        // i.e. game hours strictly below maxCoveredEpochs*eph. `hWalkEnd` is the
        // last such hour, never behind where the world already is. The
        // deterministic §5.5 overflow death (below) is NOT bound by this.
        uint256 hWalkEnd;
        if (maxCoveredEpochs == 0) {
            hWalkEnd = windowStart; // nothing pinned yet: the world cannot advance
        } else {
            uint256 maxAdvanceHour = uint256(maxCoveredEpochs) * eph - 1;
            hWalkEnd = hNow < maxAdvanceHour ? hNow : maxAdvanceHour;
            if (hWalkEnd < windowStart) hWalkEnd = windowStart;
        }
        cappedShort = hWalkEnd < hNow;

        // 1b. Release rescuers whose recovery cooldown has matured (SPEC §4.3).
        //     A rescuer who walked into an empty portal blind is parked in a
        //     cooldown cell until game hour `readyAt`; any cell that has come due
        //     by the advanced hour frees its rescuer. This is a COMPARISON against
        //     the current hour, never a per-hour loop — lazy time is preserved.
        //     `rescuersFree` is capped at `rescuersTotal`: a matured cell can only
        //     ever return a rescuer that a blind miss removed, so the count is
        //     self-balancing, but the cap defends a malformed snapshot overshooting.
        for (uint8 i = 0; i < MAX_RESCUERS; i++) {
            uint32 readyAt = rescuerReadyAt(g, i);
            if (readyAt != 0 && uint256(readyAt) <= hWalkEnd) {
                setRescuerReadyAt(g, i, 0);
                if (g.rescuersFree < c.rescuersTotal) g.rescuersFree += 1;
            }
        }

        // 2. Collect collapse events (occupied portals whose collapse hour has
        //    arrived) and tally the currently-open portals and their power yield.
        uint8[MAX_OPEN_PORTALS] memory evSlot;
        uint256[MAX_OPEN_PORTALS] memory evHour;
        uint8 evN = 0;
        uint256 openCount = 0;
        uint256 yieldSum = 0;
        for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
            if (portals[i].status == PortalStatus.Empty) continue;
            openCount += 1;
            yieldSum += uint256(types[uint8(portals[i].portalType)].powerYieldPerHour);
            // collapse hour == h(snapshotAt) + hoursToCollapse == h(collapseAt).
            uint256 ch = (uint256(portals[i].snapshotAt) - uint256(g.startedAt)) / sph + uint256(portals[i].hoursToCollapse);
            if (ch <= hWalkEnd) {
                evSlot[evN] = i;
                evHour[evN] = ch;
                evN += 1;
            }
        }
        uint256 openStart = openCount; // occupancy at the START of the window

        // 3. Insertion sort events by hour ascending (stable, ≤12 elements).
        for (uint8 a = 1; a < evN; a++) {
            uint8 slotA = evSlot[a];
            uint256 hourA = evHour[a];
            uint8 b = a;
            while (b > 0 && evHour[b - 1] > hourA) {
                evHour[b] = evHour[b - 1];
                evSlot[b] = evSlot[b - 1];
                b -= 1;
            }
            evHour[b] = hourA;
            evSlot[b] = slotA;
        }

        // 4. Walk the timeline in segments: cursor -> each event hour -> nowTs.
        //    O(events) segments, never O(hours).
        bool died = false;
        uint256 deathHour = 0;
        uint8 outN = 0;
        for (uint8 k = 0; k <= evN; k++) {
            uint256 segEnd = (k < evN) ? evHour[k] : hWalkEnd;
            uint256 delta = segEnd > cursor ? segEnd - cursor : 0; // game hours in this segment

            if (delta > 0) {
                // Resource: regen plus the yield of every open portal.
                uint256 rate = uint256(c.powerRegenPerHour) + yieldSum;
                uint256 np = uint256(g.power) + rate * delta;
                if (np > c.powerMax) np = c.powerMax;
                g.power = uint16(np);

                // Overflow: only when exactly 12 portals are open.
                if (openCount == MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0) {
                    uint256 ov = uint256(c.hpOverflowPerHour);
                    uint256 hToDeath = (uint256(g.hp) + ov - 1) / ov; // ceil(hp / ov)
                    if (hToDeath <= delta) {
                        died = true;
                        deathHour = cursor + hToDeath;
                        g.hp = 0;
                        break;
                    }
                    // hToDeath > delta ⇒ ov*delta < hp, so no underflow.
                    g.hp = uint16(uint256(g.hp) - ov * delta);
                }
            }

            if (segEnd > cursor) cursor = segEnd;

            // At the event moment: collapse the portal.
            if (k < evN) {
                uint8 s = evSlot[k];
                // Read all needed fields BEFORE zeroing the slot.
                uint256 deaths = portals[s].creaturesKnown
                    ? uint256(portals[s].creatures)
                    : (uint256(portals[s].creaturesLo) + uint256(portals[s].creaturesHi)) / 2;
                if (portals[s].observerInside) deaths += 1;
                if (portals[s].rescuerInside) deaths += 1;
                uint256 yld = uint256(types[uint8(portals[s].portalType)].powerYieldPerHour);

                // An empty collapse still costs hpEmptyCollapse — it is the
                // keeper's failure, unlike closing an empty portal (free, §4.4).
                uint256 hpLost = deaths > 0
                    ? uint256(c.hpCollapseBase) + uint256(c.hpCollapsePerDeath) * deaths
                    : uint256(c.hpEmptyCollapse);

                uint256 hpBefore = uint256(g.hp);
                uint256 actualLost = hpBefore > hpLost ? hpLost : hpBefore; // min(loss, hp before the hit)

                events[outN] = Collapse({
                    slot: s,
                    deaths: uint8(deaths),
                    hpLost: uint16(actualLost),
                    atHour: uint32(evHour[k])
                });
                outN += 1;

                g.hp = uint16(hpBefore - actualLost);

                // Crew inside dies and does NOT return to the pool (§4.3).
                // The slot is freed: a fresh zeroed portal (status == Empty).
                Portal memory blank;
                portals[s] = blank;
                openCount -= 1;
                yieldSum -= yld;

                if (g.hp == 0) {
                    died = true;
                    deathHour = evHour[k];
                    break;
                }
            }
        }

        eventCount = outN;
        g.openPortals = uint8(openCount);

        // 5. Pressure & spawns (SPEC §4.6, §5.5, §7). Only meaningful while the
        //    run survived the existing-portal collapse walk above — a death there
        //    already ended it, and spawnDebt is irrelevant to a finished game.
        if (!died) {
            uint256 debt0 = uint256(g.spawnDebt);

            // Long-absence overflow (SPEC §5.5): a DETERMINISTIC death that needs
            // NO word, so it is evaluated over the FULL window `[windowStart, hNow]`
            // even when the covered edge is nearer (the cap above only gates the
            // RANDOM spawns). If the accrued pressure could fill the lab to capacity
            // from the count open at the START of the window, the abandoned lab
            // overflows. Locate the fill hour by BINARY SEARCH (never a per-hour
            // scan); if the ensuing overflow is lethal within the window, end the
            // run analytically. If it fills but the player would survive, fall
            // through to lazy capped spawning.
            uint256 fullRaw = debt0 + spawnPressure(windowStart, hNow, c);
            uint256 needed = (MAX_OPEN_PORTALS - openStart) * uint256(c.spawnCostUnits);
            if (openStart < MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0 && fullRaw >= needed) {
                uint256 hFill = _fillHour(windowStart, hNow, debt0, needed, c);
                uint256 ov = uint256(c.hpOverflowPerHour);
                uint256 hToDeath = (uint256(g.hp) + ov - 1) / ov; // ceil(hp / ov)
                uint256 dh = hFill + hToDeath;
                if (dh <= hNow) {
                    g.spawnDebt = fullRaw > SPAWN_DEBT_MAX ? uint32(SPAWN_DEBT_MAX) : uint32(fullRaw);
                    // Create up to maxSpawnsPerTx REAL portals (the rest are
                    // pointless — the player is dead), then freeze at death. The
                    // game is ending, so predictability is moot: the fill-hour
                    // epoch is pinned by the usual split (old word for an already
                    // pinned epoch, else the new/same word).
                    (g, portals, spawns, spawnCount) = _spawn(
                        g, portals, c, types, oldWord, newWord, storedCoveredEpochs,
                        uint32(hFill), uint40(uint256(g.startedAt) + hFill * sph)
                    );
                    g.hp = 0;
                    died = true;
                    deathHour = dh;
                }
            }
            if (!died) {
                // Survived: accrue only the COVERED span into spawnDebt. The
                // uncovered tail (hWalkEnd..hNow) is not yet lived — it accrues on
                // the next call once a word pins its epochs. No pressure is lost.
                uint256 raw = debt0 + spawnPressure(windowStart, hWalkEnd, c);
                g.spawnDebt = raw > SPAWN_DEBT_MAX ? uint32(SPAWN_DEBT_MAX) : uint32(raw);
            }
        }

        // 6. Commit.
        if (died) {
            // Freeze the world at the moment of death — survivors are NOT aged.
            g.finished = true;
            g.diedAtHour = uint32(deathHour);
            g.hoursElapsed = uint32(deathHour);
            g.lastTickAt = nowTs;
        } else {
            // When the world could not reach `nowTs` (capped at the pinned edge),
            // stamp time at the edge hour, NOT `nowTs`, so the next call resumes
            // from the edge and the uncovered tail is not skipped.
            uint40 effTs = cappedShort ? uint40(uint256(g.startedAt) + hWalkEnd * sph) : nowTs;
            g.hoursElapsed = uint32(hWalkEnd);
            g.lastTickAt = effTs;
            // Age each survivor by e = hWalkEnd - h(snapshotAt) and re-snapshot.
            for (uint8 i = 0; i < MAX_OPEN_PORTALS; i++) {
                if (portals[i].status == PortalStatus.Empty) continue;
                uint256 hSnap = (uint256(portals[i].snapshotAt) - uint256(g.startedAt)) / sph;
                uint256 e = hWalkEnd - hSnap; // survivors have hoursToCollapse > e (⇒ result ≥ 1)
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
                portals[i].snapshotAt = effTs;
            }

            // Lazy spawns: create up to maxSpawnsPerTx portals from the accrued
            // pressure into the first free slots (SPEC §7), at the edge hour
            // `hWalkEnd` whose epoch is pinned by construction. New portals carry
            // snapshotAt = effTs, so the ageing loop above (which ran first) would
            // leave them untouched even if it saw them.
            // Only when the world actually advanced: `sync` is free and open to
            // anyone, and `maxSpawnsPerTx` caps a call, not a moment — without
            // this guard repeated calls in one block would spend a player's whole
            // accrued debt on portals at once. The debt waits for the next lived
            // stretch instead.
            if (hWalkEnd > windowStart) {
                (g, portals, spawns, spawnCount) = _spawn(
                    g, portals, c, types, oldWord, newWord, storedCoveredEpochs, uint32(hWalkEnd), effTs
                );
            }
        }

        return (g, portals, events, eventCount, spawns, spawnCount, cappedShort);
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

    /// @dev Smallest hour count `hh` in `[0, hNow - windowStart]` such that
    /// `debt0 + spawnPressure(windowStart, windowStart + hh) >= needed`, returned
    /// as the ABSOLUTE game hour `windowStart + hh`. Found by BINARY SEARCH with a
    /// hard cap of 64 iterations — a per-hour scan is forbidden here as everywhere
    /// (SPEC §5.5). The caller only enters when the full-window pressure already
    /// meets `needed`, so the upper bound satisfies the predicate and the search
    /// converges to the true smallest hour.
    function _fillHour(uint256 windowStart, uint256 hNow, uint256 debt0, uint256 needed, Config memory c)
        private
        pure
        returns (uint256)
    {
        uint256 lo = 0;
        uint256 hi = hNow - windowStart;
        for (uint256 it = 0; it < 64 && lo < hi; it++) {
            uint256 mid = (lo + hi) / 2;
            if (debt0 + spawnPressure(windowStart, windowStart + mid, c) >= needed) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return windowStart + lo;
    }

    /// @dev Create up to `min(spawnDebt / spawnCostUnits, maxSpawnsPerTx)` portals
    /// into the first free slots, spending `spawnCostUnits` of pressure each. The
    /// moment a portal appears is deterministic; only its CONTENTS are random
    /// (SPEC §7). Those contents now derive from the portal's EPOCH SEED, not from
    /// a per-game counter (Ticket 4.5): a portal appearing at `spawnedAtHour` draws
    /// from `epochSeed(wordFor(epoch), epoch)` where `epoch = spawnedAtHour /
    /// epochHours`. The player cannot pre-compute the word of a future epoch, so
    /// they cannot schedule their run beyond the current epoch (§6.8). `rngNonce`
    /// is still bumped per portal — it no longer feeds the spawn draw, but keeping
    /// the bump preserves the nonce stream the (unchanged) blind-rescue stub reads
    /// (Ticket 4.6 territory). Ranges are the type ranges verbatim — exact energy /
    /// stability / creatures are born at survey (SPEC §6). Names are not stored
    /// on-chain, only `nameIndex` (SPEC §7).
    function _spawn(
        Game memory g,
        Portal[MAX_OPEN_PORTALS] memory portals,
        Config memory c,
        PortalTypeParams[5] memory types,
        uint256 oldWord,
        uint256 newWord,
        uint32 storedCoveredEpochs,
        uint32 spawnedAtHour,
        uint40 nowTs
    )
        private
        pure
        returns (Game memory, Portal[MAX_OPEN_PORTALS] memory, Spawn[MAX_OPEN_PORTALS] memory outSpawns, uint8 n)
    {
        uint256 cost = uint256(c.spawnCostUnits);
        if (cost == 0) return (g, portals, outSpawns, 0); // configuration guards cost > 0
        uint256 affordable = uint256(g.spawnDebt) / cost;
        uint256 budget = affordable < uint256(c.maxSpawnsPerTx) ? affordable : uint256(c.maxSpawnsPerTx);

        // Seed for this spawn hour's epoch, pinned by the old/new word split.
        uint256 epoch = uint256(spawnedAtHour) / uint256(c.epochHours);
        uint256 seed = epochSeed(_wordFor(epoch, oldWord, newWord, storedCoveredEpochs), epoch);

        for (uint8 i = 0; i < MAX_OPEN_PORTALS && n < budget; i++) {
            if (portals[i].status != PortalStatus.Empty) continue;

            g.rngNonce += 1; // vestigial for spawns; preserves the blind-rescue nonce stream
            g.spawnCount += 1;
            uint32 spawnId = g.spawnCount; // discriminator: unique per spawn within the epoch

            PortalType pt = PortalType(uint8(_spawnDraw(seed, spawnId, SALT_TYPE) % 5));
            PortalTypeParams memory tp = types[uint256(uint8(pt))];

            // Exact, always-public collapse time inside the type's range. Computed
            // inline because the range can exceed 255 and RandomStub.inRange is
            // uint8-only.
            uint256 span = uint256(tp.hoursMax) - uint256(tp.hoursMin) + 1;
            uint16 htc = uint16(uint256(tp.hoursMin) + (_spawnDraw(seed, spawnId, SALT_HOURS) % span));
            uint16 nameIndex = uint16(_spawnDraw(seed, spawnId, SALT_NAME) % NAME_POOL_SIZE);

            Portal memory np; // built fresh, never by copy (CLAUDE.md rule)
            np.id = uint16(spawnId);
            np.portalType = pt;
            np.nameIndex = nameIndex;
            np.status = PortalStatus.Open;
            // surveyed / surveyPending / crew / exact fields stay at their zeroed
            // defaults: the portal is unsurveyed and empty of people.
            np.hoursToCollapse = htc;
            np.spawnedAtHour = spawnedAtHour;
            np.snapshotAt = nowTs;
            np.energyLo = tp.energyMin;
            np.energyHi = tp.energyMax;
            np.stabilityLo = tp.stabilityMin;
            np.stabilityHi = tp.stabilityMax;
            np.creaturesLo = tp.creaturesMin;
            np.creaturesHi = tp.creaturesMax;
            portals[i] = np;

            g.openPortals += 1;
            g.spawnDebt -= uint32(cost); // budget ≤ debt/cost ⇒ no underflow

            outSpawns[n] = Spawn({slot: i, portalType: pt, nameIndex: nameIndex, atHour: spawnedAtHour});
            n += 1;
        }

        return (g, portals, outSpawns, n);
    }
}
