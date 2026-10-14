// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {Game, Portal, Config, PortalTypeParams, PortalType, PortalStatus} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";

/// @notice Generates the golden vectors for the `TimeLib.catchUp` TS mirror:
///   ../shared/test/vectors/catchup-vectors.json
/// Run from contracts/:  forge script script/GenCatchUpVectors.s.sol
/// No RPC, no broadcast. The file format is documented in
/// shared/test/support/vectorFormat.ts (extension 4).
///
/// ── Why every config here has ZERO spawn pressure ────────────────────────────
/// This ticket mirrors all of `catchUp` EXCEPT step 5 (pressure and spawns). Step
/// 5 goes completely inert when no pressure can accrue: with
/// `basePressurePerHour == 0`, `pressureRampPerHour == 0` and a starting
/// `spawnDebt` of 0 the accumulated pressure stays 0, the fill threshold
/// `(12 - openStart) * spawnCostUnits` is unreachable (every config keeps
/// `spawnCostUnits > 0`, as the deploy validation demands), and `_spawn` gets a
/// budget of 0. So `spawns` is empty on EVERY vector here and the mirror can
/// legitimately stop at a guard. The 3b-2 ticket lifts that restriction.
///
/// ── Shape of the file ────────────────────────────────────────────────────────
/// Portal arrays are written FLAT, twelve per vector, so the existing column
/// readers work unchanged: `VectorCodec.readPortals(json, ".vectors[*].portalsIn[*]")`
/// returns 12·n portals in vector order. `typeParams` is flat too, five per set,
/// and a vector's `types` member is the SET index (params at `5·types … 5·types+4`).
/// `events` and `spawns` hold EXACTLY `eventCount` / `spawnCount` records: the
/// library returns fixed-size arrays with a separate count, and recording the tail
/// would make the tests compare uninitialised memory.
///
/// Coverage: every required case is registered by name (`_register`) and marked by
/// the vectors that reach it; the run ABORTS if any case is reached by none.
contract GenCatchUpVectors is Script {
    string private constant PATH = "../shared/test/vectors/catchup-vectors.json";

    uint256 private constant CAPACITY = 80;
    uint256 private constant CONFIG_COUNT = 7;
    uint256 private constant SET_COUNT = 3;
    uint256 private constant RANDOM = 24;

    /// @dev Every vector's `startedAt`. Game hour `h` is the timestamp
    /// `BASE + h * secPerHour`.
    uint40 private constant BASE = 1000;
    /// @dev `secPerHour` of every config but #5.
    uint256 private constant SPH = 15;

    struct Vec {
        string label;
        Game g;
        Portal[12] p;
        uint8 cfg;
        uint8 ts;
        uint256 oldWord;
        uint256 newWord;
        uint32 storedCoveredEpochs;
        uint32 maxCoveredEpochs;
        uint40 nowTs;
        // filled by _eval
        Game rg;
        Portal[12] rp;
        TimeLib.Collapse[64] ev;
        uint8 evN;
        TimeLib.Spawn[64] sp;
        uint8 spN;
        bool cappedShort;
    }

    /// @dev Values derived from a vector's inputs, recomputed here so the coverage
    /// tagger can talk about hours rather than timestamps.
    struct Derived {
        uint256 sph;
        uint256 hNow;
        uint256 windowStart;
        uint256 hWalkEnd;
        uint256 openStart;
        uint256 yieldSum;
        uint40 effTs;
    }

    /// @dev Coverage registry: a fixed list of case names and a hit counter each.
    struct Cov {
        string[] names;
        uint256[] counts;
        uint256 n;
    }

    function run() external {
        Config[] memory cfgs = _configs();
        PortalTypeParams[] memory tps = _typeParams();

        Vec[] memory vs = new Vec[](CAPACITY);
        uint256 n = _directed(vs, 0);
        uint256 directed = n;
        n = _random(vs, n, cfgs);

        Cov memory cv = _register();
        for (uint256 i = 0; i < n; i++) {
            _eval(vs[i], cfgs, tps);
            require(vs[i].spN == 0, string.concat("step 5 fired for vector: ", vs[i].label));
            _tag(cv, vs[i], cfgs[vs[i].cfg], tps);
        }
        _requireCoverage(cv);

        vm.writeFile(PATH, _head(cfgs, tps));
        _write(vs, n);
        vm.writeLine(PATH, "]}");

        console.log("catchUp vectors written:", n);
        console.log("  directed:", directed);
        console.log("  random:", n - directed);
        console.log("coverage (hits per case):");
        for (uint256 i = 0; i < cv.n; i++) {
            console.log(string.concat("  ", vm.toString(cv.counts[i]), "  ", cv.names[i]));
        }
    }

    // ── configs and type parameters ──────────────────────────────────────────

    /// @dev Seven configs, each built fresh (memory structs are references). All of
    /// them zero the two pressure coefficients — see the note at the top.
    ///   0 — the deployed GameConfig: secPerHour 15, overflow 5/h, powerMax 100,
    ///       regen 5/h, collapse 20 + 10 per death, empty collapse 3, widen 1/h,
    ///       epochHours 12, rescuersTotal 2;
    ///   1 — overflow OFF, powerMax lifted (prove twelve open portals cost nothing);
    ///   2 — powerMax lifted (watch the resource rate without a clamp);
    ///   3 — overflow 7/h (ceil(hp / ov) with a remainder);
    ///   4 — widen 30/h, empty collapse 0 (range bounds reach floor and ceiling);
    ///   5 — secPerHour 1, epochHours 1 (a much nearer covered edge);
    ///   6 — 1000 HP per death with no base, four rescuer cells.
    function _configs() private pure returns (Config[] memory cfgs) {
        cfgs = new Config[](CONFIG_COUNT);
        for (uint256 i = 0; i < CONFIG_COUNT; i++) {
            Config memory c = GameConfig.config();
            c.basePressurePerHour = 0;
            c.pressureRampPerHour = 0;
            cfgs[i] = c;
        }
        cfgs[1].hpOverflowPerHour = 0;
        cfgs[1].powerMax = 65535;

        cfgs[2].powerMax = 65535;

        cfgs[3].hpOverflowPerHour = 7;
        cfgs[3].powerMax = 65535;

        cfgs[4].rangeWidenPerHour = 30;
        cfgs[4].hpEmptyCollapse = 0;
        cfgs[4].powerMax = 65535;

        cfgs[5].secPerHour = 1;
        cfgs[5].epochHours = 1;
        cfgs[5].powerMax = 65535;

        cfgs[6].hpCollapseBase = 0;
        cfgs[6].hpCollapsePerDeath = 1000;
        cfgs[6].rescuersTotal = 4;
        cfgs[6].powerMax = 65535;
    }

    /// @dev Three sets of five `PortalTypeParams`, written flat (set `k` occupies
    /// indices `5k … 5k+4`).
    ///   0 — the canonical table (Flash degrades 6/h, LongLived 2, Deaf 3,
    ///       Resonant 5, Energetic 3 and yields 4 power/h);
    ///   1 — nothing degrades and nothing yields;
    ///   2 — everything degrades 255/h and yields 7 power/h.
    function _typeParams() private pure returns (PortalTypeParams[] memory tps) {
        tps = new PortalTypeParams[](SET_COUNT * 5);
        PortalTypeParams[5] memory canon = GameConfig.portalTypeParams();
        for (uint256 i = 0; i < 5; i++) {
            tps[i] = canon[i];

            PortalTypeParams memory flat = GameConfig.portalTypeParams()[i];
            flat.degradePerHour = 0;
            flat.powerYieldPerHour = 0;
            tps[5 + i] = flat;

            PortalTypeParams memory steep = GameConfig.portalTypeParams()[i];
            steep.degradePerHour = 255;
            steep.powerYieldPerHour = 7;
            tps[10 + i] = steep;
        }
    }

    /// @dev Set `idx` as the fixed-size table `catchUp` takes.
    function _set(PortalTypeParams[] memory tps, uint256 idx) private pure returns (PortalTypeParams[5] memory out) {
        for (uint256 i = 0; i < 5; i++) {
            out[i] = tps[idx * 5 + i];
        }
    }

    // ── fresh base states (never share a struct between two vectors) ─────────

    /// @dev Active game anchored at BASE, standing at game hour 0: hp 100,
    /// power 50, full crew, no pressure, no cooldown cell occupied.
    function _g() private pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 50;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.spawnCount = 5;
        g.rngNonce = 3;
        g.creaturesRescued = 4;
    }

    /// @dev Open, surveyed Flash portal snapshotted at BASE. The range fields are
    /// deliberately populated although a surveyed portal does not use them: the
    /// vectors then prove the surveyed branch leaves them alone.
    function _open(uint16 htc) private pure returns (Portal memory p) {
        p.id = 1;
        p.nameIndex = 2;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.stability = 100;
        p.energy = 50;
        p.hoursToCollapse = htc;
        p.snapshotAt = BASE;
        p.energyLo = 50;
        p.energyHi = 60;
        p.stabilityLo = 40;
        p.stabilityHi = 70;
        p.creaturesLo = 1;
        p.creaturesHi = 4;
    }

    /// @dev `_open` with the knowledge flags cleared: the ranges are the truth and
    /// `stability` / `energy` / `creatures` hold stale values that must not move.
    function _blind(uint16 htc) private pure returns (Portal memory p) {
        p = _open(htc);
        p.surveyed = false;
        p.creaturesKnown = false;
        p.stability = 77;
        p.creatures = 9;
    }

    function _typed(uint16 htc, PortalType t) private pure returns (Portal memory p) {
        p = _open(htc);
        p.portalType = t;
    }

    /// @dev Timestamp of game hour `h` under `sph` seconds per hour.
    function _tsOf(uint256 h, uint256 sph) private pure returns (uint40) {
        return uint40(uint256(BASE) + h * sph);
    }

    function _add(
        Vec[] memory vs,
        uint256 n,
        string memory label,
        Game memory g,
        uint8 cfg,
        uint8 ts,
        uint32 maxCoveredEpochs,
        uint40 nowTs
    ) private pure returns (uint256) {
        Vec memory v = vs[n];
        v.label = label;
        v.g = g;
        v.cfg = cfg;
        v.ts = ts;
        v.maxCoveredEpochs = maxCoveredEpochs;
        v.nowTs = nowTs;
        // The words and the split only matter to step 5, which is inert here; they
        // are still varied so a mirror that reads them wrongly is caught later.
        v.oldWord = 0xA1A2A3;
        v.newWord = 0xB1B2B3;
        v.storedCoveredEpochs = 1;
        return n + 1;
    }

    // ── directed vectors ────────────────────────────────────────────────────

    function _directed(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        n = _dEarly(vs, n);
        n = _dWindow(vs, n);
        n = _dCooldown(vs, n);
        n = _dEvents(vs, n);
        n = _dOverflow(vs, n);
        n = _dCollapseMaths(vs, n);
        n = _dCommit(vs, n);
        return n;
    }

    // Group A — the three early returns.
    function _dEarly(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Game memory g = _g();
        g.startedAt = 0;
        g.lastTickAt = 0;
        n = _add(vs, n, "early: no game (startedAt 0)", g, 0, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(50);

        g = _g();
        g.finished = true;
        g.hp = 0;
        g.diedAtHour = 7;
        g.hoursElapsed = 7;
        n = _add(vs, n, "early: the run is already finished", g, 0, 0, 100, _tsOf(40, SPH));
        vs[n - 1].p[0] = _open(50);

        n = _add(vs, n, "early: clock before the game start", _g(), 0, 0, 100, BASE - 1);
        vs[n - 1].p[0] = _open(50);
        return n;
    }

    // Group B — the covered-window edge.
    function _dWindow(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Nothing pinned: the world cannot advance at all, and the survivor whose
        // snapshot already sits at the edge does not age (e == 0).
        n = _add(vs, n, "window: nothing pinned yet (maxCoveredEpochs 0)", _g(), 0, 0, 0, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(50);
        vs[n - 1].p[1] = _open(3); // due at hour 3, but hWalkEnd is 0: not an event

        // epochHours 12, two epochs pinned -> the last advanceable hour is 23.
        Game memory g = _g();
        g.power = 0;
        n = _add(vs, n, "window: hNow past the pinned edge, stamped at the edge", g, 2, 0, 2, _tsOf(50, SPH));
        vs[n - 1].p[0] = _typed(100, PortalType.Deaf);

        n = _add(vs, n, "window: hNow before the pinned edge, stamped at nowTs", _g(), 2, 0, 10, _tsOf(30, SPH));
        vs[n - 1].p[0] = _typed(100, PortalType.Deaf);

        // The world already stands past the pinned edge: hWalkEnd is pulled up to
        // windowStart, so no hour is lived and no portal ages past its snapshot.
        g = _g();
        g.lastTickAt = _tsOf(40, SPH);
        g.hoursElapsed = 40;
        n = _add(vs, n, "window: the pinned edge lies behind the world", g, 2, 0, 2, _tsOf(50, SPH));
        vs[n - 1].p[0] = _typed(100, PortalType.Deaf);
        vs[n - 1].p[0].snapshotAt = _tsOf(40, SPH);
        vs[n - 1].p[1] = _typed(100, PortalType.Deaf);
        vs[n - 1].p[1].snapshotAt = _tsOf(10, SPH);

        // nowTs in the middle of a game hour: the division truncates to hour 10,
        // yet the stamp keeps the exact second.
        n = _add(vs, n, "window: nowTs in the middle of an hour", _g(), 2, 0, 100, _tsOf(10, SPH) + 7);
        vs[n - 1].p[0] = _typed(100, PortalType.Deaf);

        // secPerHour 1 and epochHours 1: a much nearer edge, five epochs pinned.
        n = _add(vs, n, "window: secPerHour 1, five epochs pinned", _g(), 5, 0, 5, _tsOf(20, 1));
        vs[n - 1].p[0] = _typed(100, PortalType.Deaf);
        return n;
    }

    // Group C — the rescuer cooldown ledger.
    function _dCooldown(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Game memory g = _g();
        g.rescuersFree = 1;
        g.rescuerReadyAt0 = 10; // exactly hWalkEnd: the comparison is not strict
        n = _add(vs, n, "cooldown: a cell matures exactly at hWalkEnd", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(100);

        g = _g();
        g.rescuersFree = 1;
        g.rescuerReadyAt0 = 11; // one hour late: still occupied
        n = _add(vs, n, "cooldown: a cell matures one hour past hWalkEnd", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(100);

        g = _g();
        g.rescuersFree = 2; // already rescuersTotal
        g.rescuerReadyAt0 = 5;
        n = _add(vs, n, "cooldown: the rescuersTotal ceiling holds", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(100);

        g = _g();
        g.rescuersFree = 0;
        g.rescuerReadyAt1 = 3;
        g.rescuerReadyAt2 = 50; // far in the future: untouched
        g.rescuerReadyAt3 = 7;
        n = _add(vs, n, "cooldown: two cells mature in one call (four cells, config 6)", g, 6, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(100);
        return n;
    }

    // Group D — collecting and ordering the collapses.
    function _dEvents(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // One empty collapse, and a survivor to age afterwards.
        n = _add(vs, n, "events: a single empty collapse", _g(), 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[1] = _open(100);

        // All twelve collapse, one per hour; twelve open portals also means the
        // overflow bites during the first hour and stops after the first collapse.
        Game memory g = _g();
        g.power = 0;
        n = _add(vs, n, "events: all twelve portals collapse", g, 2, 0, 100, _tsOf(20, SPH));
        for (uint8 i = 0; i < 12; i++) {
            vs[n - 1].p[i] = _open(uint16(i) + 1);
        }

        // Three collapses in the SAME hour: the sort is stable, so the events come
        // out in slot order. Distinct creature counts make the order observable.
        g = _g();
        g.hp = 200;
        n = _add(vs, n, "events: three collapses in one hour, ordered by slot", g, 2, 0, 100, _tsOf(8, SPH));
        vs[n - 1].p[1] = _open(5);
        vs[n - 1].p[1].creatures = 1;
        vs[n - 1].p[3] = _open(5);
        vs[n - 1].p[3].creatures = 2;
        vs[n - 1].p[7] = _open(5);
        vs[n - 1].p[7].creatures = 3;
        vs[n - 1].p[9] = _open(100);

        // Due exactly at hWalkEnd: in. Due one hour later: out.
        n = _add(vs, n, "events: due exactly at hWalkEnd, and one hour past it", _g(), 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(10);
        vs[n - 1].p[1] = _open(11);
        return n;
    }

    // Group E1 — the resource and the twelve-portal overflow.
    function _dOverflow(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Game memory g = _g();
        g.power = 90;
        n = _add(vs, n, "walk: the resource clamps at powerMax", g, 0, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(100);

        g = _g();
        g.power = 0;
        n = _add(vs, n, "walk: regen plus the yield of two energetic portals", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _typed(100, PortalType.Energetic);
        vs[n - 1].p[1] = _typed(100, PortalType.Energetic);

        g = _g();
        g.power = 0;
        n = _add(vs, n, "walk: a collapsing energetic portal lowers the next segment's rate", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _typed(5, PortalType.Energetic);
        vs[n - 1].p[1] = _typed(100, PortalType.Energetic);

        n = _add(vs, n, "walk: eleven open portals do not overflow", _g(), 2, 0, 100, _tsOf(10, SPH));
        for (uint8 i = 0; i < 11; i++) {
            vs[n - 1].p[i] = _open(1000);
        }

        n = _add(vs, n, "walk: twelve open portals with overflow off", _g(), 1, 0, 100, _tsOf(10, SPH));
        for (uint8 i = 0; i < 12; i++) {
            vs[n - 1].p[i] = _open(1000);
        }

        // ceil(hp / ov) with an exact division: 50 / 5 = 10.
        Game memory g50 = _g();
        g50.hp = 50;
        n = _add(vs, n, "walk: overflow death, hp divides exactly", g50, 2, 0, 100, _tsOf(20, SPH));
        for (uint8 i = 0; i < 12; i++) {
            vs[n - 1].p[i] = _open(1000);
        }

        // ceil(hp / ov) with a remainder: ceil(50 / 7) = 8.
        g50 = _g();
        g50.hp = 50;
        n = _add(vs, n, "walk: overflow death, ceil with a remainder (overflow 7)", g50, 3, 0, 100, _tsOf(20, SPH));
        for (uint8 i = 0; i < 12; i++) {
            vs[n - 1].p[i] = _open(1000);
        }

        // ceil(52 / 5) = 11: the hour of death rounds UP, never down.
        Game memory g52 = _g();
        g52.hp = 52;
        n = _add(vs, n, "walk: overflow death, ceil rounds the hour up", g52, 2, 0, 100, _tsOf(20, SPH));
        for (uint8 i = 0; i < 12; i++) {
            vs[n - 1].p[i] = _open(1000);
        }
        return n;
    }

    // Group E2 — what a collapse costs.
    function _dCollapseMaths(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // hp exactly equal to the loss: the non-strict test takes hp, and the run
        // ends at the hour of the event.
        Game memory g = _g();
        g.hp = 30;
        n = _add(vs, n, "walk: a collapse takes hp to exactly zero", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].creatures = 1;
        vs[n - 1].p[1] = _open(100);

        // Loss above the remaining hp: the EVENT records min(loss, hp before).
        g = _g();
        g.hp = 10;
        n = _add(vs, n, "walk: the loss exceeds the remaining hp", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].creatures = 1;
        vs[n - 1].p[1] = _open(100);

        // Unknown creature count: the midpoint of the range, truncated — and the
        // stale exact field must be ignored.
        g = _g();
        g.hp = 200;
        n = _add(vs, n, "walk: unknown creature count uses the truncated midpoint", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _blind(5);
        vs[n - 1].p[1] = _open(100);

        g = _g();
        g.hp = 200;
        n = _add(vs, n, "walk: an observer inside the collapsing portal dies", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].observerInside = true;

        g = _g();
        g.hp = 200;
        n = _add(vs, n, "walk: a rescuer inside the collapsing portal dies", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].rescuerInside = true;

        g = _g();
        g.hp = 200;
        n = _add(vs, n, "walk: both crew inside, plus two creatures", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].creatures = 2;
        vs[n - 1].p[0].observerInside = true;
        vs[n - 1].p[0].rescuerInside = true;

        // 255 creatures plus both crew: 257 deaths truncate to 1 in the event,
        // while the HP loss is charged for all 257.
        g = _g();
        g.hp = 5000;
        n = _add(vs, n, "walk: 257 deaths truncate to uint8 in the event", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(5);
        vs[n - 1].p[0].creatures = 255;
        vs[n - 1].p[0].observerInside = true;
        vs[n - 1].p[0].rescuerInside = true;
        vs[n - 1].p[1] = _open(100);

        // Death at the FIRST of three due collapses: the other two are not emitted
        // and their portals stay untouched.
        g = _g();
        g.hp = 30;
        n = _add(vs, n, "walk: death mid-walk, the later collapses are not emitted", g, 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _open(2);
        vs[n - 1].p[0].creatures = 1;
        vs[n - 1].p[1] = _open(4);
        vs[n - 1].p[1].creatures = 1;
        vs[n - 1].p[2] = _open(6);
        vs[n - 1].p[2].creatures = 1;
        return n;
    }

    // Group F — ageing the survivors and re-stamping them.
    function _dCommit(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Deaf degrades 3/h: one survivor floors at zero, the other does not.
        n = _add(vs, n, "commit: stability degrades, and floors at zero", _g(), 2, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _typed(1000, PortalType.Deaf);
        vs[n - 1].p[0].stability = 10;
        vs[n - 1].p[1] = _typed(1000, PortalType.Deaf);

        // Unsurveyed, widen 1/h over ten hours: both bounds move, nothing clamps,
        // the creature range and the stale exact fields stay put.
        n = _add(vs, n, "commit: an unsurveyed portal's bounds drift apart", _g(), 0, 0, 100, _tsOf(10, SPH));
        vs[n - 1].p[0] = _blind(1000);

        // Widen 30/h over four hours: 120 pushes the low bounds to 0 and the high
        // bounds to the hard ceiling of 100.
        n = _add(vs, n, "commit: the drifting bounds reach floor and ceiling", _g(), 4, 0, 100, _tsOf(4, SPH));
        vs[n - 1].p[0] = _blind(1000);

        // A portal snapshotted before the window ages over the WHOLE gap from its
        // own snapshot, not just over the hours lived in this call.
        Game memory g = _g();
        g.lastTickAt = _tsOf(20, SPH);
        g.hoursElapsed = 20;
        n = _add(vs, n, "commit: ageing runs from the portal's own snapshot", g, 2, 0, 100, _tsOf(30, SPH));
        vs[n - 1].p[0] = _typed(1000, PortalType.Deaf);
        vs[n - 1].p[1] = _typed(1000, PortalType.Deaf);
        vs[n - 1].p[1].snapshotAt = _tsOf(20, SPH);
        return n;
    }

    // ── random vectors ──────────────────────────────────────────────────────

    function _r(uint256 i, string memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("portal-lab-catchup-v1", i, tag)));
    }

    /// @dev Random but CONSISTENT states: a portal is never snapshotted after the
    /// world's own clock, and `lastTickAt` never precedes `startedAt`. Both would
    /// underflow a uint256 subtraction inside `catchUp`, and this file has no
    /// vocabulary for a revert — the inputs a real game can reach are enough.
    /// `spawnDebt` stays 0 so step 5 remains inert (see the note at the top).
    function _random(Vec[] memory vs, uint256 n, Config[] memory cfgs) private pure returns (uint256) {
        for (uint256 i = 0; i < RANDOM; i++) {
            uint256 x = _r(i, "vec");
            Vec memory v = vs[n];
            v.label = "random";
            v.cfg = uint8(_r(i, "cfg") % CONFIG_COUNT);
            v.ts = uint8(_r(i, "ts") % SET_COUNT);
            uint256 sph = cfgs[v.cfg].secPerHour;

            uint256 w = (x >> 8) % 60; // the hour the world already stands at
            uint256 d = (x >> 24) % 200; // hours to advance
            v.g = _g();
            v.g.lastTickAt = _tsOf(w, sph);
            v.g.hoursElapsed = uint32(w);
            v.g.hp = uint16(1 + (x >> 40) % 300);
            v.g.power = uint16((x >> 56) % 120);
            v.g.rescuersFree = uint8((x >> 72) % 3);
            v.g.rescuerReadyAt0 = (x >> 80) % 3 == 0 ? uint32((x >> 84) % 80) : 0;
            v.g.rescuerReadyAt1 = (x >> 96) % 3 == 0 ? uint32((x >> 100) % 80) : 0;
            v.g.rescuerReadyAt2 = (x >> 112) % 4 == 0 ? uint32((x >> 116) % 80) : 0;
            v.g.rescuerReadyAt3 = (x >> 128) % 4 == 0 ? uint32((x >> 132) % 80) : 0;
            v.nowTs = uint40(uint256(_tsOf(w + d, sph)) + (x >> 144) % sph);
            v.maxCoveredEpochs = (x >> 160) % 5 == 0 ? 0 : uint32(1 + (x >> 164) % 30);
            v.storedCoveredEpochs = uint32((x >> 184) % 10);
            v.oldWord = _r(i, "old");
            v.newWord = _r(i, "new");

            for (uint8 s = 0; s < 12; s++) {
                uint256 y = _r(i * 16 + s, "portal");
                if (y % 4 == 0) continue; // the slot stays Empty
                Portal memory p;
                p.id = uint16(1 + (y >> 4) % 500);
                p.portalType = PortalType((y >> 8) % 5);
                p.nameIndex = uint16((y >> 12) % 24);
                p.status = (y >> 16) % 4 == 0 ? PortalStatus.Questioned : PortalStatus.Open;
                p.surveyed = (y >> 20) % 3 != 0;
                p.creaturesKnown = p.surveyed ? (y >> 24) % 8 != 0 : (y >> 24) % 3 == 0;
                p.observerInside = (y >> 28) % 5 == 0;
                p.rescuerInside = (y >> 32) % 5 == 0;
                p.stability = uint8((y >> 36) % 101);
                p.energy = uint8((y >> 44) % 101);
                p.creatures = (y >> 52) % 40 == 0 ? 255 : uint8((y >> 56) % 8);
                p.hoursToCollapse = uint16((y >> 64) % 120);
                uint256 snap = (y >> 80) % (w + 1);
                p.spawnedAtHour = uint32(snap);
                p.snapshotAt = _tsOf(snap, sph);
                p.energyLo = uint8((y >> 96) % 101);
                p.energyHi = uint8(uint256(p.energyLo) + (y >> 104) % (101 - uint256(p.energyLo)));
                p.stabilityLo = uint8((y >> 112) % 101);
                p.stabilityHi = uint8(uint256(p.stabilityLo) + (y >> 120) % (101 - uint256(p.stabilityLo)));
                p.creaturesLo = uint8((y >> 128) % 6);
                p.creaturesHi = uint8(uint256(p.creaturesLo) + (y >> 136) % 7);
                v.p[s] = p;
            }
            n++;
        }
        return n;
    }

    // ── evaluation ──────────────────────────────────────────────────────────

    /// @dev `catchUp` mutates its `Game` and `Portal[12]` IN PLACE — memory structs
    /// are passed by reference — so it is handed DEEP COPIES. Without them the
    /// vector's recorded input would be overwritten by the output and every row
    /// would read as a no-op. `abi.encode`/`abi.decode` copies every field without
    /// a hand-written field list that could silently drift from the struct.
    function _eval(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps) private pure {
        Game memory gIn = abi.decode(abi.encode(v.g), (Game));
        Portal[12] memory pIn = abi.decode(abi.encode(v.p), (Portal[12]));
        (
            Game memory rg,
            Portal[12] memory rp,
            TimeLib.Collapse[64] memory ev,
            uint8 evN,
            TimeLib.Spawn[64] memory sp,
            uint8 spN,
            bool capped
        ) = TimeLib.catchUp(
            gIn,
            pIn,
            cfgs[v.cfg],
            _set(tps, v.ts),
            v.oldWord,
            v.newWord,
            v.storedCoveredEpochs,
            v.maxCoveredEpochs,
            v.nowTs
        );
        v.rg = rg;
        for (uint256 i = 0; i < 12; i++) {
            v.rp[i] = rp[i];
        }
        for (uint256 i = 0; i < evN; i++) {
            v.ev[i] = ev[i];
        }
        v.evN = evN;
        for (uint256 i = 0; i < spN; i++) {
            v.sp[i] = sp[i];
        }
        v.spN = spN;
        v.cappedShort = capped;
    }

    // ── coverage ────────────────────────────────────────────────────────────

    function _reg(Cov memory cv, string memory name) private pure {
        cv.names[cv.n] = name;
        cv.n++;
    }

    /// @dev Every case the ticket requires. `_mark` with a name not in this list
    /// reverts, so a typo cannot quietly invent a case nobody checks.
    function _register() private pure returns (Cov memory cv) {
        cv.names = new string[](64);
        cv.counts = new uint256[](64);

        _reg(cv, "early: startedAt == 0");
        _reg(cv, "early: finished");
        _reg(cv, "early: nowTs < startedAt");

        _reg(cv, "window: maxCoveredEpochs == 0, the world cannot move");
        _reg(cv, "window: hNow past the edge, cappedShort, stamped at the edge");
        _reg(cv, "window: hNow before the edge, not capped, stamped at nowTs");
        _reg(cv, "window: the edge behind the world, hWalkEnd pulled up to windowStart");
        _reg(cv, "window: nowTs exactly on an hour boundary");
        _reg(cv, "window: nowTs in the middle of an hour (truncating division)");

        _reg(cv, "cooldown: a cell matures exactly at hWalkEnd");
        _reg(cv, "cooldown: a cell matures one hour past hWalkEnd, not released");
        _reg(cv, "cooldown: rescuersFree already at rescuersTotal, the ceiling holds");
        _reg(cv, "cooldown: two cells mature in one call");

        _reg(cv, "events: none");
        _reg(cv, "events: one");
        _reg(cv, "events: twelve, every portal collapses");
        _reg(cv, "events: two portals at one hour, ordered by slot");
        _reg(cv, "events: due exactly at hWalkEnd, included");
        _reg(cv, "events: due one hour past hWalkEnd, excluded");

        _reg(cv, "walk: the resource clamps at powerMax");
        _reg(cv, "walk: regen with a nonzero open-portal yield");
        _reg(cv, "walk: the yield drops after a collapse, next segment at the new rate");
        _reg(cv, "walk: twelve open, hp flows");
        _reg(cv, "walk: eleven open, hp does not flow");
        _reg(cv, "walk: hpOverflowPerHour == 0, no flow even at twelve");
        _reg(cv, "walk: overflow death inside a segment, deathHour = cursor + ceil(hp/ov)");
        _reg(cv, "walk: ceil(hp/ov) with an exact division");
        _reg(cv, "walk: ceil(hp/ov) with a remainder");
        _reg(cv, "walk: a collapse takes hp to exactly zero, death at the event hour");
        _reg(cv, "walk: loss above the remaining hp, the event records min(loss, hp)");
        _reg(cv, "walk: an empty collapse costs hpEmptyCollapse, zero deaths");
        _reg(cv, "walk: creaturesKnown true");
        _reg(cv, "walk: creaturesKnown false, (lo + hi) / 2 truncated");
        _reg(cv, "walk: an observer inside");
        _reg(cv, "walk: a rescuer inside");
        _reg(cv, "walk: both crew inside");
        _reg(cv, "walk: deaths above 255 truncate to uint8");
        _reg(cv, "walk: death mid-walk, the later events are not emitted");

        _reg(cv, "commit: surveyed survivor, stability drops by degradePerHour * e");
        _reg(cv, "commit: surveyed survivor, stability floors at zero");
        _reg(cv, "commit: unsurveyed survivor, bounds widen by rangeWidenPerHour * e");
        _reg(cv, "commit: unsurveyed survivor, a low bound floors at zero");
        _reg(cv, "commit: unsurveyed survivor, a high bound caps at 100");
        _reg(cv, "commit: unsurveyed survivor, the creature range is untouched");
        _reg(cv, "commit: hoursToCollapse decreases by e");
        _reg(cv, "commit: snapshotAt re-stamped to effTs");
        _reg(cv, "commit: a survivor with e == 0 does not age");
    }

    function _mark(Cov memory cv, bool cond, string memory name) private pure {
        if (!cond) return;
        bytes32 h = keccak256(bytes(name));
        for (uint256 i = 0; i < cv.n; i++) {
            if (keccak256(bytes(cv.names[i])) == h) {
                cv.counts[i]++;
                return;
            }
        }
        revert(string.concat("unregistered coverage case: ", name));
    }

    function _requireCoverage(Cov memory cv) private pure {
        for (uint256 i = 0; i < cv.n; i++) {
            require(cv.counts[i] > 0, string.concat("case not covered by any vector: ", cv.names[i]));
        }
    }

    function _derive(Vec memory v, Config memory c, PortalTypeParams[] memory tps)
        private
        pure
        returns (Derived memory d)
    {
        d.sph = c.secPerHour;
        d.hNow = (uint256(v.nowTs) - uint256(v.g.startedAt)) / d.sph;
        d.windowStart = (uint256(v.g.lastTickAt) - uint256(v.g.startedAt)) / d.sph;
        if (v.maxCoveredEpochs == 0) {
            d.hWalkEnd = d.windowStart;
        } else {
            uint256 maxAdvanceHour = uint256(v.maxCoveredEpochs) * uint256(c.epochHours) - 1;
            d.hWalkEnd = d.hNow < maxAdvanceHour ? d.hNow : maxAdvanceHour;
            if (d.hWalkEnd < d.windowStart) d.hWalkEnd = d.windowStart;
        }
        for (uint256 i = 0; i < 12; i++) {
            if (v.p[i].status == PortalStatus.Empty) continue;
            d.openStart += 1;
            d.yieldSum += uint256(tps[uint256(v.ts) * 5 + uint8(v.p[i].portalType)].powerYieldPerHour);
        }
        d.effTs = v.cappedShort ? uint40(uint256(v.g.startedAt) + d.hWalkEnd * d.sph) : v.nowTs;
    }

    function _tag(Cov memory cv, Vec memory v, Config memory c, PortalTypeParams[] memory tps) private pure {
        if (v.g.startedAt == 0 || v.g.finished || v.nowTs < v.g.startedAt) {
            _mark(cv, v.g.startedAt == 0, "early: startedAt == 0");
            _mark(cv, v.g.startedAt != 0 && v.g.finished, "early: finished");
            _mark(cv, v.g.startedAt != 0 && !v.g.finished, "early: nowTs < startedAt");
            return;
        }
        Derived memory d = _derive(v, c, tps);
        _tagWindow(cv, v, c, d);
        _tagCooldown(cv, v, c, d);
        _tagEvents(cv, v, d);
        _tagWalk(cv, v, c, d);
        _tagCommit(cv, v, c, d, tps);
    }

    function _tagWindow(Cov memory cv, Vec memory v, Config memory c, Derived memory d) private pure {
        _mark(cv, v.maxCoveredEpochs == 0, "window: maxCoveredEpochs == 0, the world cannot move");
        _mark(
            cv,
            v.maxCoveredEpochs != 0 && v.cappedShort && !v.rg.finished && v.rg.lastTickAt == d.effTs
                && d.effTs != v.nowTs,
            "window: hNow past the edge, cappedShort, stamped at the edge"
        );
        _mark(
            cv,
            !v.cappedShort && !v.rg.finished && d.hNow > d.windowStart && v.rg.lastTickAt == v.nowTs,
            "window: hNow before the edge, not capped, stamped at nowTs"
        );
        _mark(
            cv,
            v.maxCoveredEpochs != 0 && uint256(v.maxCoveredEpochs) * uint256(c.epochHours) - 1 < d.windowStart
                && d.hWalkEnd == d.windowStart,
            "window: the edge behind the world, hWalkEnd pulled up to windowStart"
        );
        bool lived = d.hWalkEnd > d.windowStart;
        _mark(
            cv,
            lived && (uint256(v.nowTs) - uint256(v.g.startedAt)) % d.sph == 0,
            "window: nowTs exactly on an hour boundary"
        );
        _mark(
            cv,
            lived && (uint256(v.nowTs) - uint256(v.g.startedAt)) % d.sph != 0,
            "window: nowTs in the middle of an hour (truncating division)"
        );
    }

    function _readyAt(Game memory g, uint8 i) private pure returns (uint32) {
        if (i == 0) return g.rescuerReadyAt0;
        if (i == 1) return g.rescuerReadyAt1;
        if (i == 2) return g.rescuerReadyAt2;
        return g.rescuerReadyAt3;
    }

    function _tagCooldown(Cov memory cv, Vec memory v, Config memory c, Derived memory d) private pure {
        uint256 matured;
        for (uint8 i = 0; i < 4; i++) {
            uint32 was = _readyAt(v.g, i);
            uint32 now_ = _readyAt(v.rg, i);
            if (was != 0 && uint256(was) <= d.hWalkEnd) matured += 1;
            _mark(
                cv,
                was != 0 && uint256(was) == d.hWalkEnd && now_ == 0,
                "cooldown: a cell matures exactly at hWalkEnd"
            );
            _mark(
                cv,
                was != 0 && uint256(was) == d.hWalkEnd + 1 && now_ == was,
                "cooldown: a cell matures one hour past hWalkEnd, not released"
            );
            _mark(
                cv,
                was != 0 && uint256(was) <= d.hWalkEnd && v.g.rescuersFree == c.rescuersTotal
                    && v.rg.rescuersFree == c.rescuersTotal,
                "cooldown: rescuersFree already at rescuersTotal, the ceiling holds"
            );
        }
        _mark(cv, matured >= 2, "cooldown: two cells mature in one call");
    }

    /// @dev The collapse hour of a portal, as step 2 computes it.
    function _collapseHour(Vec memory v, uint256 slot, Derived memory d) private pure returns (uint256) {
        return (uint256(v.p[slot].snapshotAt) - uint256(v.g.startedAt)) / d.sph + uint256(v.p[slot].hoursToCollapse);
    }

    function _hasEventFor(Vec memory v, uint256 slot) private pure returns (bool) {
        for (uint8 i = 0; i < v.evN; i++) {
            if (v.ev[i].slot == uint8(slot)) return true;
        }
        return false;
    }

    function _deathsFor(Portal memory p) private pure returns (uint256 deaths) {
        deaths = p.creaturesKnown ? uint256(p.creatures) : (uint256(p.creaturesLo) + uint256(p.creaturesHi)) / 2;
        if (p.observerInside) deaths += 1;
        if (p.rescuerInside) deaths += 1;
    }

    function _lossFor(Portal memory p, Config memory c) private pure returns (uint256) {
        uint256 deaths = _deathsFor(p);
        return deaths > 0 ? uint256(c.hpCollapseBase) + uint256(c.hpCollapsePerDeath) * deaths : uint256(c.hpEmptyCollapse);
    }

    function _tagEvents(Cov memory cv, Vec memory v, Derived memory d) private pure {
        _mark(cv, v.evN == 0, "events: none");
        _mark(cv, v.evN == 1, "events: one");
        _mark(cv, v.evN == 12, "events: twelve, every portal collapses");
        for (uint8 a = 0; a < v.evN; a++) {
            _mark(cv, uint256(v.ev[a].atHour) == d.hWalkEnd, "events: due exactly at hWalkEnd, included");
            for (uint8 b = a + 1; b < v.evN; b++) {
                _mark(
                    cv,
                    v.ev[a].atHour == v.ev[b].atHour && v.ev[a].slot < v.ev[b].slot,
                    "events: two portals at one hour, ordered by slot"
                );
            }
        }
        // A portal one hour beyond the edge must have been left alone: no event
        // names its slot, and (unless the run ended) it is still occupied.
        for (uint256 s = 0; s < 12; s++) {
            if (v.p[s].status == PortalStatus.Empty) continue;
            _mark(
                cv,
                _collapseHour(v, s, d) == d.hWalkEnd + 1 && !_hasEventFor(v, s)
                    && v.rp[s].status != PortalStatus.Empty,
                "events: due one hour past hWalkEnd, excluded"
            );
        }
        // Collapses that were DUE but never emitted mean the walk stopped at a death.
        uint256 due;
        for (uint256 s = 0; s < 12; s++) {
            if (v.p[s].status == PortalStatus.Empty) continue;
            if (_collapseHour(v, s, d) <= d.hWalkEnd) due += 1;
        }
        _mark(
            cv,
            v.rg.finished && v.evN >= 1 && due > v.evN,
            "walk: death mid-walk, the later events are not emitted"
        );
    }

    function _tagWalk(Cov memory cv, Vec memory v, Config memory c, Derived memory d) private pure {
        bool lived = d.hWalkEnd > d.windowStart;
        _mark(cv, v.rg.power == c.powerMax && v.g.power < c.powerMax, "walk: the resource clamps at powerMax");
        _mark(
            cv,
            lived && d.yieldSum > 0 && v.rg.power > v.g.power && v.rg.power < c.powerMax,
            "walk: regen with a nonzero open-portal yield"
        );
        _mark(
            cv,
            !v.rg.finished && v.evN >= 1 && d.yieldSum > 0
                && (v.evN == 1 ? d.hWalkEnd : uint256(v.ev[1].atHour)) > uint256(v.ev[0].atHour)
                && uint256(v.ev[0].atHour) > d.windowStart,
            "walk: the yield drops after a collapse, next segment at the new rate"
        );
        _mark(
            cv,
            lived && d.openStart == 12 && c.hpOverflowPerHour > 0 && v.rg.hp < v.g.hp,
            "walk: twelve open, hp flows"
        );
        _mark(
            cv,
            lived && d.openStart == 11 && c.hpOverflowPerHour > 0 && v.evN == 0 && v.rg.hp == v.g.hp,
            "walk: eleven open, hp does not flow"
        );
        _mark(
            cv,
            lived && d.openStart == 12 && c.hpOverflowPerHour == 0 && v.evN == 0 && v.rg.hp == v.g.hp,
            "walk: hpOverflowPerHour == 0, no flow even at twelve"
        );
        // An overflow death with no event in the way: the hour is computable here.
        bool ovDeath = v.rg.finished && v.evN == 0 && d.openStart == 12 && c.hpOverflowPerHour > 0;
        uint256 ov = c.hpOverflowPerHour == 0 ? 1 : uint256(c.hpOverflowPerHour);
        uint256 hToDeath = (uint256(v.g.hp) + ov - 1) / ov;
        ovDeath = ovDeath && uint256(v.rg.diedAtHour) == d.windowStart + hToDeath;
        _mark(cv, ovDeath, "walk: overflow death inside a segment, deathHour = cursor + ceil(hp/ov)");
        _mark(cv, ovDeath && uint256(v.g.hp) % ov == 0, "walk: ceil(hp/ov) with an exact division");
        _mark(cv, ovDeath && uint256(v.g.hp) % ov != 0, "walk: ceil(hp/ov) with a remainder");
        _tagCollapseMaths(cv, v, c);
    }

    function _tagCollapseMaths(Cov memory cv, Vec memory v, Config memory c) private pure {
        for (uint8 k = 0; k < v.evN; k++) {
            Portal memory p = v.p[v.ev[k].slot];
            uint256 deaths = _deathsFor(p);
            uint256 loss = _lossFor(p, c);
            bool last = k + 1 == v.evN;
            _mark(
                cv,
                last && v.rg.finished && v.rg.hp == 0 && uint256(v.rg.diedAtHour) == uint256(v.ev[k].atHour)
                    && uint256(v.ev[k].hpLost) == loss,
                "walk: a collapse takes hp to exactly zero, death at the event hour"
            );
            _mark(
                cv,
                uint256(v.ev[k].hpLost) < loss,
                "walk: loss above the remaining hp, the event records min(loss, hp)"
            );
            _mark(
                cv,
                deaths == 0 && v.ev[k].deaths == 0 && uint256(v.ev[k].hpLost) == uint256(c.hpEmptyCollapse),
                "walk: an empty collapse costs hpEmptyCollapse, zero deaths"
            );
            _mark(cv, p.creaturesKnown && p.creatures > 0, "walk: creaturesKnown true");
            _mark(
                cv,
                !p.creaturesKnown && (uint256(p.creaturesLo) + uint256(p.creaturesHi)) % 2 == 1,
                "walk: creaturesKnown false, (lo + hi) / 2 truncated"
            );
            _mark(cv, p.observerInside && !p.rescuerInside, "walk: an observer inside");
            _mark(cv, p.rescuerInside && !p.observerInside, "walk: a rescuer inside");
            _mark(cv, p.observerInside && p.rescuerInside, "walk: both crew inside");
            _mark(cv, deaths > 255 && uint256(v.ev[k].deaths) == deaths % 256, "walk: deaths above 255 truncate to uint8");
        }
    }

    function _tagCommit(Cov memory cv, Vec memory v, Config memory c, Derived memory d, PortalTypeParams[] memory tps)
        private
        pure
    {
        if (v.rg.finished) return; // a dead world freezes: nothing is aged
        for (uint256 s = 0; s < 12; s++) {
            Portal memory p = v.p[s];
            if (p.status == PortalStatus.Empty) continue;
            if (v.rp[s].status == PortalStatus.Empty) continue; // collapsed in this call
            Portal memory q = v.rp[s];
            uint256 e = d.hWalkEnd - (uint256(p.snapshotAt) - uint256(v.g.startedAt)) / d.sph;
            uint256 deg = uint256(tps[uint256(v.ts) * 5 + uint8(p.portalType)].degradePerHour) * e;
            uint256 widen = uint256(c.rangeWidenPerHour) * e;

            _mark(
                cv,
                p.surveyed && e > 0 && deg > 0 && uint256(p.stability) > deg
                    && uint256(q.stability) == uint256(p.stability) - deg,
                "commit: surveyed survivor, stability drops by degradePerHour * e"
            );
            _mark(
                cv,
                p.surveyed && e > 0 && p.stability > 0 && deg >= uint256(p.stability) && q.stability == 0,
                "commit: surveyed survivor, stability floors at zero"
            );
            _mark(
                cv,
                !p.surveyed && widen > 0 && uint256(p.energyLo) > widen && uint256(p.energyHi) + widen <= 100
                    && uint256(q.energyLo) == uint256(p.energyLo) - widen
                    && uint256(q.energyHi) == uint256(p.energyHi) + widen,
                "commit: unsurveyed survivor, bounds widen by rangeWidenPerHour * e"
            );
            _mark(
                cv,
                !p.surveyed && p.energyLo > 0 && widen >= uint256(p.energyLo) && q.energyLo == 0,
                "commit: unsurveyed survivor, a low bound floors at zero"
            );
            _mark(
                cv,
                !p.surveyed && uint256(p.energyHi) + widen > 100 && q.energyHi == 100,
                "commit: unsurveyed survivor, a high bound caps at 100"
            );
            _mark(
                cv,
                !p.surveyed && widen > 0 && (p.creaturesLo > 0 || p.creaturesHi > 0)
                    && q.creaturesLo == p.creaturesLo && q.creaturesHi == p.creaturesHi,
                "commit: unsurveyed survivor, the creature range is untouched"
            );
            _mark(
                cv,
                e > 0 && uint256(p.hoursToCollapse) > e && uint256(q.hoursToCollapse) == uint256(p.hoursToCollapse) - e,
                "commit: hoursToCollapse decreases by e"
            );
            _mark(cv, q.snapshotAt == d.effTs && p.snapshotAt != d.effTs, "commit: snapshotAt re-stamped to effTs");
            _mark(
                cv,
                e == 0 && q.stability == p.stability && q.hoursToCollapse == p.hoursToCollapse
                    && q.energyLo == p.energyLo && q.energyHi == p.energyHi && q.stabilityLo == p.stabilityLo
                    && q.stabilityHi == p.stabilityHi,
                "commit: a survivor with e == 0 does not age"
            );
        }
    }

    // ── output ──────────────────────────────────────────────────────────────

    function _head(Config[] memory cfgs, PortalTypeParams[] memory tps) private pure returns (string memory) {
        string memory s = '{"configs":[';
        for (uint256 i = 0; i < cfgs.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.configJson(cfgs[i]));
        }
        s = string.concat(s, '],"typeParams":[');
        for (uint256 i = 0; i < tps.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.typeParamsJson(tps[i]));
        }
        return string.concat(s, '],"vectors":[');
    }

    function _write(Vec[] memory vs, uint256 n) private {
        for (uint256 i = 0; i < n; i++) {
            // Each line builds hundreds of throw-away strings and EVM memory is
            // never freed; rewinding the free-memory pointer after the write keeps
            // the run inside Foundry's memory cap. Nothing built inside the
            // iteration is used after it. (Same idiom as GenTimeVectors.)
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _line(vs[i], i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    function _portalsJson(Portal[12] memory ps) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < 12; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.portalJson(ps[i]));
        }
        s = string.concat(s, "]");
    }

    function _eventsJson(TimeLib.Collapse[64] memory ev, uint8 n) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < n; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.collapseJson(ev[i]));
        }
        s = string.concat(s, "]");
    }

    function _spawnsJson(TimeLib.Spawn[64] memory sp, uint8 n) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < n; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.spawnJson(sp[i]));
        }
        s = string.concat(s, "]");
    }

    function _line(Vec memory v, bool last) private pure returns (string memory) {
        string memory inputs = string.concat(
            '{"label":"', v.label, '",',
            '"game":', VectorCodec.gameJson(v.g), ",",
            '"portalsIn":', _portalsJson(v.p), ",",
            VectorCodec.kv("config", v.cfg), ",",
            VectorCodec.kv("types", v.ts), ",",
            VectorCodec.ks("oldWord", v.oldWord), ",",
            VectorCodec.ks("newWord", v.newWord), ","
        );
        string memory scalars = string.concat(
            VectorCodec.kv("storedCoveredEpochs", v.storedCoveredEpochs), ",",
            VectorCodec.kv("maxCoveredEpochs", v.maxCoveredEpochs), ",",
            VectorCodec.kv("nowTs", v.nowTs), ","
        );
        string memory expected = string.concat(
            '"expected":{',
            '"game":', VectorCodec.gameJson(v.rg), ",",
            '"portalsOut":', _portalsJson(v.rp), ",",
            '"events":', _eventsJson(v.ev, v.evN), ",",
            '"spawns":', _spawnsJson(v.sp, v.spN), ",",
            VectorCodec.kb("cappedShort", v.cappedShort),
            "}}"
        );
        return string.concat(inputs, scalars, expected, last ? "" : ",");
    }
}
