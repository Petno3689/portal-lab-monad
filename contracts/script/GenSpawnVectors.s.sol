// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {
    Game,
    Portal,
    Config,
    PortalTypeParams,
    PortalType,
    PortalStatus,
    MAX_OPEN_PORTALS,
    SPAWN_DEBT_MAX
} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";
import {TimeHarness} from "../test/utils/TimeHarness.sol";

/// @notice Generates the golden vectors for step 5 of `TimeLib.catchUp` — spawn
/// pressure, the deterministic long-absence overflow death and the spawns both
/// branches pay for:
///   ../shared/test/vectors/spawn-vectors.json
/// Run from contracts/:  forge script script/GenSpawnVectors.s.sol
/// No RPC, no broadcast. The file format is documented in
/// shared/test/support/vectorFormat.ts (extension 5).
///
/// ── Why a second file and not more rows in catchup-vectors.json ──────────────
/// catchup-vectors.json is built entirely on ZERO-pressure configs, which is what
/// makes step 5 provably inert there; that file is a regression witness and is
/// never regenerated. Everything here has pressure, so every config carries a
/// nonzero `basePressurePerHour` and the `spawns` arrays are mostly NOT empty.
///
/// ── Shape of the file ────────────────────────────────────────────────────────
/// Identical to catchup-vectors.json (portal arrays flat, twelve per vector;
/// `typeParams` flat, five per set; `events` / `spawns` holding exactly the
/// records that happened), plus a second array:
///
///   "refusals": rows in the same input shape whose `expected` is only
///   `{reverted, error}`. `catchUp` is a public path and is NOT total: called with
///   a `lastTickAt` ahead of `nowTs` it can underflow. Those rows prove the
///   mirror falls over in the same place and the same way, instead of inventing
///   an answer.
///
/// Coverage: every required case is registered by name (`_register`) and marked by
/// the vectors that reach it; the run ABORTS if any case is reached by none.
contract GenSpawnVectors is Script {
    string private constant PATH = "../shared/test/vectors/spawn-vectors.json";

    uint256 private constant CAPACITY = 80;
    uint256 private constant REFUSALS = 8;
    uint256 private constant CONFIG_COUNT = 8;
    uint256 private constant SET_COUNT = 3;
    uint256 private constant RANDOM = 24;

    /// @dev Every vector's `startedAt`. Game hour `h` is the timestamp
    /// `BASE + h * secPerHour`.
    uint40 private constant BASE = 1000;
    /// @dev `secPerHour` of every config but #4.
    uint256 private constant SPH = 15;

    /// @dev Default words. They differ, always: a vector whose spawn draws came
    /// from the wrong one of the two must look different, not accidentally equal.
    uint256 private constant OLD_WORD = 0xA1A2A3;
    uint256 private constant NEW_WORD = 0xB1B2B3;

    uint32 private constant U32_MAX = 4294967295;

    struct Vec {
        string label;
        Game g;
        Portal[12] p;
        uint8 cfg;
        uint8 ts;
        uint256 oldWord;
        uint256 newWord;
        uint32 stored;
        uint32 maxCov;
        uint40 nowTs;
        // filled by _eval
        Game rg;
        Portal[12] rp;
        TimeLib.Collapse[12] ev;
        uint8 evN;
        TimeLib.Spawn[12] sp;
        uint8 spN;
        bool cappedShort;
        bool reverted;
        string err;
    }

    /// @dev Values derived from a vector's inputs, recomputed here so the coverage
    /// tagger can talk about hours and pressure rather than timestamps. NOTHING
    /// here feeds the recorded expectations — those always come from the library.
    struct Derived {
        uint256 sph;
        uint256 hNow;
        uint256 windowStart;
        uint256 hWalkEnd;
        uint256 openStart;
        uint40 effTs;
        uint256 needed;
        uint256 fullRaw;
        uint256 covered;
        uint256 hFill;
        uint256 affordable;
        uint256 budget;
        uint256 freeAfter;
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
        TimeHarness h = new TimeHarness();

        Vec[] memory vs = new Vec[](CAPACITY);
        uint256 n = _directed(vs, 0, cfgs, tps);
        uint256 directed = n;
        n = _random(vs, n, cfgs);

        Vec[] memory rf = new Vec[](REFUSALS);
        uint256 nr = _refusals(rf, 0);

        Cov memory cv = _register();
        uint256 spawnTotal;
        for (uint256 i = 0; i < n; i++) {
            _eval(vs[i], cfgs, tps);
            spawnTotal += vs[i].spN;
            _tag(cv, vs[i], cfgs, tps);
        }
        for (uint256 i = 0; i < nr; i++) {
            _evalRefusal(rf[i], cfgs, tps, h);
            require(rf[i].reverted, string.concat("refusal vector did not revert: ", rf[i].label));
            _tagRefusal(cv, rf[i]);
        }
        require(spawnTotal > 0, "not a single spawn in the whole corpus");
        _requireCoverage(cv);

        vm.writeFile(PATH, _head(cfgs, tps));
        _write(vs, n, false);
        vm.writeLine(PATH, '],"refusals":[');
        _write(rf, nr, true);
        vm.writeLine(PATH, "]}");

        console.log("spawn vectors written:", n);
        console.log("  directed:", directed);
        console.log("  random:", n - directed);
        console.log("refusal vectors written:", nr);
        console.log("spawns recorded in total:", spawnTotal);
        console.log("coverage (hits per case):");
        for (uint256 i = 0; i < cv.n; i++) {
            console.log(string.concat("  ", vm.toString(cv.counts[i]), "  ", cv.names[i]));
        }
    }

    // ── configs and type parameters ──────────────────────────────────────────

    /// @dev Eight configs, each built fresh (memory structs are references).
    ///   0 — the deployed GameConfig verbatim: 1000 pressure/h with a ramp of 1,
    ///       10000 per portal, 3 spawns per tx, overflow 5/h, epochHours 12;
    ///   1 — 10000 pressure/h flat: exactly one portal's worth per game hour,
    ///       which makes every fill hour in the comments checkable by eye;
    ///   2 — as 1, overflow OFF (the §5.5 death branch is never considered);
    ///   3 — as 1, spawnCostUnits 0 (`needed` collapses to zero);
    ///   4 — as 1, secPerHour 1 and epochHours 1 (an epoch per game hour, so the
    ///       old/new word split is easy to place);
    ///   5 — as 1, 1e9 pressure/h (saturates spawnDebt at SPAWN_DEBT_MAX);
    ///   6 — as 1, 100 pressure/h (pressure accrues but buys nothing);
    ///   7 — as 1, maxSpawnsPerTx 1.
    function _configs() private pure returns (Config[] memory cfgs) {
        cfgs = new Config[](CONFIG_COUNT);
        cfgs[0] = GameConfig.config();
        for (uint256 i = 1; i < CONFIG_COUNT; i++) {
            Config memory c = GameConfig.config();
            c.basePressurePerHour = 10_000;
            c.pressureRampPerHour = 0;
            c.powerMax = 65535; // the resource clamp is catchup-vectors' business
            cfgs[i] = c;
        }
        cfgs[2].hpOverflowPerHour = 0;

        cfgs[3].spawnCostUnits = 0;

        cfgs[4].secPerHour = 1;
        cfgs[4].epochHours = 1;

        cfgs[5].basePressurePerHour = 1_000_000_000;

        cfgs[6].basePressurePerHour = 100;

        cfgs[7].maxSpawnsPerTx = 1;
    }

    /// @dev Three sets of five `PortalTypeParams`, written flat (set `k` occupies
    /// indices `5k … 5k+4`).
    ///   0 — the canonical table;
    ///   1 — every type lives exactly 20 hours (hoursMin == hoursMax, span one);
    ///   2 — every type spans the whole uint16 range (1 … 65535).
    function _typeParams() private pure returns (PortalTypeParams[] memory tps) {
        tps = new PortalTypeParams[](SET_COUNT * 5);
        PortalTypeParams[5] memory canon = GameConfig.portalTypeParams();
        for (uint256 i = 0; i < 5; i++) {
            tps[i] = canon[i];

            PortalTypeParams memory fixedLife = GameConfig.portalTypeParams()[i];
            fixedLife.hoursMin = 20;
            fixedLife.hoursMax = 20;
            fixedLife.degradePerHour = 0;
            tps[5 + i] = fixedLife;

            PortalTypeParams memory wide = GameConfig.portalTypeParams()[i];
            wide.hoursMin = 1;
            wide.hoursMax = 65535;
            wide.degradePerHour = 0;
            tps[10 + i] = wide;
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
    /// power 50, full crew, no pressure yet, no cooldown cell occupied.
    function _g() private pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 50;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.spawnCount = 5; // the next spawn is id 6
        g.rngNonce = 3;
        g.creaturesRescued = 4;
    }

    /// @dev Open, surveyed Flash portal snapshotted at BASE, no creatures inside:
    /// its collapse costs `hpEmptyCollapse` and kills nobody, which keeps the
    /// occupancy arithmetic of this file readable.
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
        uint32 stored,
        uint32 maxCov,
        uint40 nowTs
    ) private pure returns (uint256) {
        Vec memory v = vs[n];
        v.label = label;
        v.g = g;
        v.cfg = cfg;
        v.ts = ts;
        v.stored = stored;
        v.maxCov = maxCov;
        v.nowTs = nowTs;
        v.oldWord = OLD_WORD;
        v.newWord = NEW_WORD;
        return n + 1;
    }

    /// @dev Fill slots `0 … k-1` with portals that outlive any window here.
    function _fill(Vec[] memory vs, uint256 n, uint8 k) private pure {
        for (uint8 i = 0; i < k; i++) {
            vs[n - 1].p[i] = _open(1000);
        }
    }

    // ── directed vectors ────────────────────────────────────────────────────

    function _directed(Vec[] memory vs, uint256 n, Config[] memory cfgs, PortalTypeParams[] memory tps)
        private
        pure
        returns (uint256)
    {
        n = _dDeath(vs, n);
        n = _dSurvive(vs, n);
        n = _dSpawns(vs, n);
        n = _dEpoch(vs, n);
        n = _dHunted(vs, n, cfgs, tps);
        return n;
    }

    // Group A — the deterministic long-absence overflow death (SPEC §5.5).
    //
    // Config 1 makes every number here readable: pressure is 10000 per game hour
    // and a portal costs 10000, so an empty lab (needed = 12 * 10000) fills at
    // game hour 12 and `hToDeath` is ceil(hp / 5).
    function _dDeath(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // hFill 12, hToDeath 1, death at hour 13, inside the window (hNow 20).
        Game memory g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: an empty lab fills and the overflow kills inside the window", g, 1, 0, 1, 2, _tsOf(20, SPH));

        // The debt ALONE already meets `needed`, so the fill hour is windowStart
        // itself — and windowStart is 4, not 0, so a mirror that confuses the two
        // is caught. Spawn hour 4 sits in epoch 0, pinned by the OLD word.
        g = _g();
        g.hp = 5;
        g.spawnDebt = 120_000;
        g.lastTickAt = _tsOf(4, SPH);
        g.hoursElapsed = 4;
        n = _add(vs, n, "death: the debt alone fills the lab, so hFill is windowStart", g, 1, 0, 1, 2, _tsOf(10, SPH));

        // dh == hNow exactly: the bound is not strict, so this still dies.
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: the hour of death lands exactly on hNow", g, 1, 0, 1, 2, _tsOf(13, SPH));

        // THE case of the ticket: the FULL window reaches `needed` where the
        // covered span does not. maxCoveredEpochs 1 puts the pinned edge at hour
        // 11; pressure to hour 11 is 110000 < 120000, pressure to hour 30 is
        // 300000. The §5.5 death needs no word, so the edge does not hold it back.
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: the full window reaches needed where the covered span does not", g, 1, 0, 1, 1, _tsOf(30, SPH));

        // Twelve portals open: `needed` is zero and the pressure is ample, yet the
        // branch is not considered at all — only the occupancy test stops it.
        g = _g();
        g.hp = 100;
        n = _add(vs, n, "death: not considered, twelve portals are already open", g, 1, 0, 1, 1, _tsOf(2, SPH));
        _fill(vs, n, 12);

        // Overflow off: a full lab costs nothing, so there is nothing to die of.
        n = _add(vs, n, "death: not considered, hpOverflowPerHour is zero", _g(), 2, 0, 1, 2, _tsOf(20, SPH));

        // A portal that costs nothing makes `needed` zero, so the condition holds
        // for ANY pressure, the fill hour is windowStart and the lab dies — while
        // `_spawn` returns at once and creates nothing.
        g = _g();
        g.hp = 10;
        n = _add(vs, n, "death: spawnCostUnits zero makes needed zero, and nothing spawns", g, 3, 0, 1, 1, _tsOf(10, SPH));

        // Pressure of 1e9 per hour: the debt saturates at SPAWN_DEBT_MAX on the
        // way into the death branch.
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: the debt saturates at SPAWN_DEBT_MAX", g, 5, 0, 1, 1, _tsOf(5, SPH));
        return n;
    }

    // Group B — the survival branch: what the debt does when nobody dies.
    function _dSurvive(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // The lab fills at hour 12 but 100 hp buys 20 more hours, so death (hour
        // 32) is past hNow (20): the run survives and spawns from the debt.
        n = _add(vs, n, "survive: the lab fills but the death falls past the window", _g(), 1, 0, 1, 2, _tsOf(20, SPH));

        // The fill hour is hNow itself (debt 110000 plus one hour of pressure
        // meets 120000 exactly at hour 1), so the death is necessarily ahead.
        Game memory g = _g();
        g.spawnDebt = 110_000;
        n = _add(vs, n, "survive: the lab fills only at hNow, the death is still ahead", g, 1, 0, 1, 1, _tsOf(1, SPH));

        // 100 units an hour for ten hours: the debt grows and still buys nothing.
        n = _add(vs, n, "survive: the debt accrues, no portal affordable yet", _g(), 6, 0, 1, 1, _tsOf(10, SPH));

        // 1e9 an hour for five hours: the debt saturates at SPAWN_DEBT_MAX in the
        // survival branch, then pays for the per-transaction maximum.
        n = _add(vs, n, "survive: the debt saturates at SPAWN_DEBT_MAX", _g(), 5, 0, 1, 1, _tsOf(5, SPH));

        // Capped short: hNow is 30, the pinned edge is hour 11. Only the covered
        // span accrues (1100), never the full window's 3000 — the tail waits for
        // a word.
        n = _add(vs, n, "survive: the debt accrues over the covered span only", _g(), 6, 0, 1, 1, _tsOf(30, SPH));
        return n;
    }

    // Group C — how many portals appear, and where.
    function _dSpawns(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // maxSpawnsPerTx 1: two hours of pressure could buy two, the cap allows one.
        n = _add(vs, n, "spawn: exactly one portal, the per-transaction cap is one", _g(), 7, 0, 1, 1, _tsOf(2, SPH));

        // Debt 100000 plus one hour: eleven portals affordable, three allowed,
        // twelve slots free. The cap binds, not the purse and not the room.
        Game memory g = _g();
        g.spawnDebt = 100_000;
        n = _add(vs, n, "spawn: the per-transaction cap of three binds", g, 1, 0, 1, 1, _tsOf(1, SPH));

        // Eleven slots taken: the budget is two, the room is one.
        n = _add(vs, n, "spawn: fewer free slots than the budget allows", _g(), 1, 0, 1, 1, _tsOf(2, SPH));
        _fill(vs, n, 11);

        // A collapse at hour 1 frees slot 0, and the pressure refills it in the
        // same call — proof the spawn loop sees the freed slot, not a stale one.
        n = _add(vs, n, "spawn: a collapse frees a slot and the pressure refills it at once", _g(), 1, 0, 1, 1, _tsOf(2, SPH));
        vs[n - 1].p[0] = _open(1);

        // Every type lives exactly twenty hours: span one, and the hours draw
        // cannot move the result.
        n = _add(vs, n, "spawn: hoursMin == hoursMax, the span is one", _g(), 1, 1, 1, 1, _tsOf(2, SPH));

        // The span is the whole uint16 range: the modulo is wide and the cast to
        // uint16 is exercised at its limit.
        n = _add(vs, n, "spawn: a life span spanning the whole uint16 range", _g(), 1, 2, 1, 1, _tsOf(2, SPH));

        // The canonical config: a ramped pressure (1000 + 1 per lived hour) over a
        // long absence, ending in the overflow death. Nothing contrived — this is
        // the shape a real abandoned lab has.
        g = _g();
        g.hp = 20;
        n = _add(vs, n, "spawn: the deployed config over a long absence", g, 0, 0, 1, 30, _tsOf(200, SPH));
        return n;
    }

    // Group D — which word pins the spawn hour's epoch.
    function _dEpoch(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Config 4: one game hour per epoch (and one second per game hour), so the
        // spawn hour IS its epoch. Hour 2 with five epochs pinned -> the OLD word.
        n = _add(vs, n, "epoch: the spawn hour is pinned by the old word", _g(), 4, 0, 5, 3, _tsOf(2, 1));

        // The same world with one epoch pinned -> hour 2 is beyond it, so the NEW
        // word applies. Everything else is identical, so the two rows together are
        // a direct demonstration that the choice of word is observable.
        n = _add(vs, n, "epoch: the spawn hour is pinned by the new word", _g(), 4, 0, 1, 3, _tsOf(2, 1));
        return n;
    }

    // Group E — vectors whose WORD is hunted for, because no hand-picked constant
    // can be known in advance to land a keccak draw on a particular value.
    function _dHunted(Vec[] memory vs, uint256 n, Config[] memory cfgs, PortalTypeParams[] memory tps)
        private
        pure
        returns (uint256)
    {
        n = _addNameHunt(vs, n, cfgs, tps, 0);
        n = _addNameHunt(vs, n, cfgs, tps, 23);
        n = _addDistinctHunt(vs, n, cfgs, tps);
        return n;
    }

    /// @dev The one-spawn probe world: config 7 (cap of one), the canonical types,
    /// an empty lab, two lived hours, nothing pinned (`stored` 0) so the NEW word
    /// is the one that pins epoch 0 and the hunt has something to vary.
    function _probeName(Config[] memory cfgs, PortalTypeParams[] memory tps, uint256 word)
        private
        pure
        returns (uint8 spN, uint16 nameIndex)
    {
        Game memory g = _g();
        Portal[12] memory p;
        TimeLib.Spawn[12] memory sp;
        (,,,, sp, spN,) = TimeLib.catchUp(g, p, cfgs[7], _set(tps, 0), OLD_WORD, word, 0, 1, _tsOf(2, SPH));
        nameIndex = spN > 0 ? sp[0].nameIndex : 0;
    }

    /// @dev Searches for a word whose single spawn draws `target` as its name, then
    /// records that world as a vector. The hunt runs the REAL library, so it cannot
    /// drift from the draw formula the way a re-implementation of keccak would.
    function _addNameHunt(
        Vec[] memory vs,
        uint256 n,
        Config[] memory cfgs,
        PortalTypeParams[] memory tps,
        uint16 target
    ) private pure returns (uint256) {
        uint256 word;
        bool found;
        for (uint256 k = 0; k < 600 && !found; k++) {
            uint256 cand = uint256(keccak256(abi.encode("portal-lab-spawn-name", target, k)));
            (uint8 spN, uint16 nameIndex) = _probeName(cfgs, tps, cand);
            if (spN == 1 && nameIndex == target) {
                word = cand;
                found = true;
            }
        }
        require(found, "no word found whose spawn draws the target nameIndex");
        n = _add(
            vs,
            n,
            string.concat("spawn: a word whose draw lands on nameIndex ", vm.toString(uint256(target))),
            _g(),
            7,
            0,
            0,
            1,
            _tsOf(2, SPH)
        );
        vs[n - 1].newWord = word;
        return n;
    }

    /// @dev The two-spawn probe world: config 1 (cap of three, but two hours of
    /// pressure buy exactly two), canonical types, empty lab, nothing pinned.
    function _probeDistinct(Config[] memory cfgs, PortalTypeParams[] memory tps, uint256 word)
        private
        pure
        returns (bool)
    {
        Game memory g = _g();
        Portal[12] memory p;
        (, Portal[12] memory rp,,, TimeLib.Spawn[12] memory sp, uint8 spN,) =
            TimeLib.catchUp(g, p, cfgs[1], _set(tps, 0), OLD_WORD, word, 0, 1, _tsOf(2, SPH));
        if (spN < 2) return false;
        return sp[0].portalType != sp[1].portalType && sp[0].nameIndex != sp[1].nameIndex
            && rp[sp[0].slot].hoursToCollapse != rp[sp[1].slot].hoursToCollapse;
    }

    /// @dev Searches for a word under which the two spawns of one call differ in
    /// ALL THREE drawn values. Only `spawnId` separates them, so this is the proof
    /// that the discriminator really reaches every sub-draw.
    function _addDistinctHunt(Vec[] memory vs, uint256 n, Config[] memory cfgs, PortalTypeParams[] memory tps)
        private
        pure
        returns (uint256)
    {
        uint256 word;
        bool found;
        for (uint256 k = 0; k < 600 && !found; k++) {
            uint256 cand = uint256(keccak256(abi.encode("portal-lab-spawn-distinct", k)));
            if (_probeDistinct(cfgs, tps, cand)) {
                word = cand;
                found = true;
            }
        }
        require(found, "no word found whose two spawns differ in all three draws");
        n = _add(vs, n, "spawn: two in one call differ in type, hours and name", _g(), 1, 0, 0, 1, _tsOf(2, SPH));
        vs[n - 1].newWord = word;
        return n;
    }

    // ── refusal vectors ─────────────────────────────────────────────────────

    /// @dev `catchUp` is not total. Every row here is a reachable input on which
    /// the contract PANICS, recorded so both replayers can prove they fall over in
    /// the same place and the same way.
    ///
    /// The first three walk the same road: `nowTs` BEHIND `lastTickAt` (a stale
    /// snapshot — a caller holding an old timestamp, never the live chain) makes
    /// `hNow < windowStart`, and if the standing debt alone already meets `needed`
    /// the fill-hour search computes `hNow - windowStart` and underflows. The last
    /// two are the per-spawn counters at their uint32 ceiling: the next spawn
    /// increments `rngNonce`, then `spawnCount`, and a `uint32` at its maximum
    /// cannot take the increment.
    function _refusals(Vec[] memory rf, uint256 n) private pure returns (uint256) {
        // Empty lab, needed 120000, debt 150000, the clock five hours behind.
        Game memory g = _g();
        g.spawnDebt = 150_000;
        g.lastTickAt = _tsOf(10, SPH);
        g.hoursElapsed = 10;
        n = _add(rf, n, "refusal: a stale clock underflows the fill-hour search", g, 1, 0, 1, 2, _tsOf(5, SPH));

        // Half the lab occupied (needed 60000) and the debt exactly meeting it:
        // the condition is reached by equality, not by a wide margin.
        g = _g();
        g.spawnDebt = 60_000;
        g.lastTickAt = _tsOf(20, SPH);
        g.hoursElapsed = 20;
        n = _add(rf, n, "refusal: a stale clock, the debt meeting needed exactly", g, 1, 0, 1, 2, _tsOf(3, SPH));
        _fill(rf, n, 6);

        // The same underflow one second before the window start, under config 4
        // (one second per game hour), where a single second of staleness is a
        // whole game hour.
        g = _g();
        g.spawnDebt = 120_000;
        g.lastTickAt = _tsOf(9, 1);
        g.hoursElapsed = 9;
        n = _add(rf, n, "refusal: a stale clock by a single game hour", g, 4, 0, 1, 20, _tsOf(8, 1));

        // rngNonce at the ceiling: the spawn's first act is to bump it.
        g = _g();
        g.rngNonce = U32_MAX;
        n = _add(rf, n, "refusal: rngNonce at the uint32 ceiling", g, 1, 0, 1, 1, _tsOf(2, SPH));

        // spawnCount at the ceiling: rngNonce has room, the id counter has not.
        g = _g();
        g.spawnCount = U32_MAX;
        n = _add(rf, n, "refusal: spawnCount at the uint32 ceiling", g, 1, 0, 1, 1, _tsOf(2, SPH));
        return n;
    }

    // ── random vectors ──────────────────────────────────────────────────────

    function _r(uint256 i, string memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("portal-lab-spawn-v1", i, tag)));
    }

    /// @dev Random but CONSISTENT states: a portal is never snapshotted after the
    /// world's own clock, `lastTickAt` never precedes `startedAt`, `nowTs` never
    /// precedes `lastTickAt`, and the two uint32 counters stay far from their
    /// ceiling. Every one of those would make the call REVERT, and a reverting row
    /// belongs in the refusal section where it is recorded on purpose, not here.
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
            v.g.spawnDebt = uint32((x >> 64) % 400_000);
            v.g.spawnCount = uint32((x >> 88) % 50);
            v.g.rescuersFree = uint8((x >> 72) % 3);
            v.g.rescuerReadyAt0 = (x >> 80) % 3 == 0 ? uint32((x >> 84) % 80) : 0;
            v.nowTs = uint40(uint256(_tsOf(w + d, sph)) + (x >> 144) % sph);
            v.maxCov = (x >> 160) % 5 == 0 ? 0 : uint32(1 + (x >> 164) % 30);
            v.stored = uint32((x >> 184) % 10);
            v.oldWord = _r(i, "old");
            v.newWord = _r(i, "new");

            for (uint8 s = 0; s < 12; s++) {
                uint256 y = _r(i * 16 + s, "portal");
                if (y % 3 == 0) continue; // the slot stays Empty
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
                p.creatures = uint8((y >> 56) % 8);
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
            TimeLib.Collapse[12] memory ev,
            uint8 evN,
            TimeLib.Spawn[12] memory sp,
            uint8 spN,
            bool capped
        ) = TimeLib.catchUp(
            gIn, pIn, cfgs[v.cfg], _set(tps, v.ts), v.oldWord, v.newWord, v.stored, v.maxCov, v.nowTs
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

    /// @dev A refusal row is evaluated through the HARNESS: an internal library
    /// revert is not catchable, an external one is.
    function _evalRefusal(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps, TimeHarness h)
        private
        view
    {
        try h.catchUp(v.g, v.p, cfgs[v.cfg], _set(tps, v.ts), v.oldWord, v.newWord, v.stored, v.maxCov, v.nowTs) {
            v.reverted = false;
        } catch (bytes memory err) {
            v.reverted = true;
            v.err = VectorCodec.errorName(err);
        }
    }

    // ── coverage ────────────────────────────────────────────────────────────

    function _reg(Cov memory cv, string memory name) private pure {
        cv.names[cv.n] = name;
        cv.n++;
    }

    /// @dev Every case the ticket requires. `_mark` with a name not in this list
    /// reverts, so a typo cannot quietly invent a case nobody checks.
    function _register() private pure returns (Cov memory cv) {
        cv.names = new string[](48);
        cv.counts = new uint256[](48);

        _reg(cv, "death: the pressure fills the lab and the death lands inside the window");
        _reg(cv, "death: the lab fills but the death falls past the window, the run survives");
        _reg(cv, "death: not considered, openStart == 12");
        _reg(cv, "death: not considered, hpOverflowPerHour == 0");
        _reg(cv, "death: spawnCostUnits == 0 makes needed zero, the branch fires, nothing spawns");
        _reg(cv, "death: hFill lands exactly on windowStart");
        _reg(cv, "death: hFill lands exactly on hNow");
        _reg(cv, "death: the hour of death equals hNow (the bound is not strict)");
        _reg(cv, "death: the full window reaches needed where the covered span does not");
        _reg(cv, "death: spawnDebt saturates at SPAWN_DEBT_MAX");

        _reg(cv, "survive: the debt accrues, no portal affordable yet");
        _reg(cv, "survive: spawnDebt saturates at SPAWN_DEBT_MAX");
        _reg(cv, "survive: the debt accrues over the covered span only, the tail is left");

        _reg(cv, "spawn: exactly one portal created");
        _reg(cv, "spawn: maxSpawnsPerTx created, the per-transaction cap binds");
        _reg(cv, "spawn: fewer free slots than the budget allows");
        _reg(cv, "spawn: no free slot at all, nothing created");
        _reg(cv, "spawn: two in one call differ in type, hours and name");
        _reg(cv, "spawn: the hour's epoch is pinned by the old word");
        _reg(cv, "spawn: the hour's epoch is pinned by the new word");
        _reg(cv, "spawn: the old and the new word differ, and the result shows it");
        _reg(cv, "spawn: hoursMin == hoursMax, the span is one");
        _reg(cv, "spawn: nameIndex 0");
        _reg(cv, "spawn: nameIndex 23");
        _reg(cv, "spawn: created in the death branch");
        _reg(cv, "spawn: created in the survival branch");

        _reg(cv, "refusal: a stale clock underflows the fill-hour search");
        _reg(cv, "refusal: rngNonce at the uint32 ceiling");
        _reg(cv, "refusal: spawnCount at the uint32 ceiling");
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

    /// @dev The fill hour, recomputed for the coverage names ONLY (so a case can
    /// say "hFill lands on windowStart" rather than describe a timestamp). Same
    /// binary search as the library; nothing recorded in the file depends on it.
    function _fillHourTag(uint256 windowStart, uint256 hNow, uint256 debt0, uint256 needed, Config memory c)
        private
        pure
        returns (uint256)
    {
        uint256 lo = 0;
        uint256 hi = hNow - windowStart;
        for (uint256 it = 0; it < 64 && lo < hi; it++) {
            uint256 mid = (lo + hi) / 2;
            if (debt0 + TimeLib.spawnPressure(windowStart, windowStart + mid, c) >= needed) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return windowStart + lo;
    }

    function _derive(Vec memory v, Config memory c) private pure returns (Derived memory d) {
        d.sph = c.secPerHour;
        d.hNow = (uint256(v.nowTs) - uint256(v.g.startedAt)) / d.sph;
        d.windowStart = (uint256(v.g.lastTickAt) - uint256(v.g.startedAt)) / d.sph;
        if (v.maxCov == 0) {
            d.hWalkEnd = d.windowStart;
        } else {
            uint256 maxAdvanceHour = uint256(v.maxCov) * uint256(c.epochHours) - 1;
            d.hWalkEnd = d.hNow < maxAdvanceHour ? d.hNow : maxAdvanceHour;
            if (d.hWalkEnd < d.windowStart) d.hWalkEnd = d.windowStart;
        }
        for (uint256 i = 0; i < 12; i++) {
            if (v.p[i].status != PortalStatus.Empty) d.openStart += 1;
            if (v.rp[i].status == PortalStatus.Empty) d.freeAfter += 1;
        }
        d.effTs = v.cappedShort ? uint40(uint256(v.g.startedAt) + d.hWalkEnd * d.sph) : v.nowTs;
        d.needed = (MAX_OPEN_PORTALS - d.openStart) * uint256(c.spawnCostUnits);
        d.fullRaw = uint256(v.g.spawnDebt) + TimeLib.spawnPressure(d.windowStart, d.hNow, c);
        d.covered = uint256(v.g.spawnDebt) + TimeLib.spawnPressure(d.windowStart, d.hWalkEnd, c);
        d.hFill = _fillHourTag(d.windowStart, d.hNow, uint256(v.g.spawnDebt), d.needed, c);
        // What `_spawn` had to spend: the death branch hands it the FULL window's
        // pressure, the survival branch only the covered span. Both saturate.
        uint256 debtAtSpawn = v.rg.finished ? d.fullRaw : d.covered;
        if (debtAtSpawn > SPAWN_DEBT_MAX) debtAtSpawn = SPAWN_DEBT_MAX;
        d.affordable = c.spawnCostUnits == 0 ? 0 : debtAtSpawn / uint256(c.spawnCostUnits);
        d.budget = d.affordable < uint256(c.maxSpawnsPerTx) ? d.affordable : uint256(c.maxSpawnsPerTx);
    }

    /// @dev True when swapping the two words changes what was drawn — the proof
    /// that the old/new split is not decoration. Runs the real library again.
    function _differsOnWordSwap(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps)
        private
        pure
        returns (bool)
    {
        if (v.spN == 0 || v.oldWord == v.newWord) return false;
        Game memory gIn = abi.decode(abi.encode(v.g), (Game));
        Portal[12] memory pIn = abi.decode(abi.encode(v.p), (Portal[12]));
        (, Portal[12] memory rp2,,, TimeLib.Spawn[12] memory sp2, uint8 n2,) = TimeLib.catchUp(
            gIn, pIn, cfgs[v.cfg], _set(tps, v.ts), v.newWord, v.oldWord, v.stored, v.maxCov, v.nowTs
        );
        if (n2 != v.spN) return true;
        uint8 s = v.sp[0].slot;
        return sp2[0].portalType != v.sp[0].portalType || sp2[0].nameIndex != v.sp[0].nameIndex
            || rp2[s].hoursToCollapse != v.rp[s].hoursToCollapse;
    }

    function _tag(Cov memory cv, Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps) private pure {
        Config memory c = cfgs[v.cfg];
        if (v.g.startedAt == 0 || v.g.finished || v.nowTs < v.g.startedAt) return; // step 5 is never reached
        Derived memory d = _derive(v, c);

        // A step-5 death is the ONLY way a finished game can carry spawns: the
        // collapse walk ends the run before step 5, and step 6 only spawns when
        // the run survived. So `finished && spN > 0` identifies the branch exactly,
        // with no need to guess how much hp the walk left behind.
        bool deathSpawned = v.rg.finished && v.spN > 0;
        bool entered = d.openStart < MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0 && d.fullRaw >= d.needed;

        _mark(cv, deathSpawned && uint256(v.sp[0].atHour) == d.hFill && uint256(v.rg.diedAtHour) <= d.hNow,
            "death: the pressure fills the lab and the death lands inside the window");
        _mark(cv, !v.rg.finished && entered,
            "death: the lab fills but the death falls past the window, the run survives");
        _mark(cv, d.openStart == MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0 && !v.rg.finished,
            "death: not considered, openStart == 12");
        _mark(cv, c.hpOverflowPerHour == 0 && d.openStart < MAX_OPEN_PORTALS && d.fullRaw >= d.needed && !v.rg.finished,
            "death: not considered, hpOverflowPerHour == 0");
        _mark(cv, c.spawnCostUnits == 0 && d.openStart < MAX_OPEN_PORTALS && c.hpOverflowPerHour > 0
            && v.rg.finished && v.spN == 0 && v.evN == 0,
            "death: spawnCostUnits == 0 makes needed zero, the branch fires, nothing spawns");
        _mark(cv, deathSpawned && uint256(v.sp[0].atHour) == d.windowStart, "death: hFill lands exactly on windowStart");
        _mark(cv, !v.rg.finished && entered && d.hFill == d.hNow, "death: hFill lands exactly on hNow");
        _mark(cv, deathSpawned && uint256(v.rg.diedAtHour) == d.hNow,
            "death: the hour of death equals hNow (the bound is not strict)");
        _mark(cv, deathSpawned && d.fullRaw >= d.needed && d.covered < d.needed,
            "death: the full window reaches needed where the covered span does not");
        _mark(cv, deathSpawned && d.fullRaw > SPAWN_DEBT_MAX, "death: spawnDebt saturates at SPAWN_DEBT_MAX");

        _mark(cv, !v.rg.finished && v.spN == 0 && v.rg.spawnDebt > v.g.spawnDebt
            && uint256(v.rg.spawnDebt) < uint256(c.spawnCostUnits),
            "survive: the debt accrues, no portal affordable yet");
        _mark(cv, !v.rg.finished && d.covered > SPAWN_DEBT_MAX, "survive: spawnDebt saturates at SPAWN_DEBT_MAX");
        _mark(cv, !v.rg.finished && v.cappedShort && d.covered < d.fullRaw && v.spN == 0
            && uint256(v.rg.spawnDebt) == d.covered,
            "survive: the debt accrues over the covered span only, the tail is left");

        _tagSpawns(cv, v, c, d, cfgs, tps);
    }

    function _tagSpawns(
        Cov memory cv,
        Vec memory v,
        Config memory c,
        Derived memory d,
        Config[] memory cfgs,
        PortalTypeParams[] memory tps
    ) private pure {
        _mark(cv, v.spN == 1, "spawn: exactly one portal created");
        _mark(cv, v.spN == c.maxSpawnsPerTx && d.affordable > uint256(c.maxSpawnsPerTx)
            && d.freeAfter > 0,
            "spawn: maxSpawnsPerTx created, the per-transaction cap binds");
        _mark(cv, v.spN > 0 && v.spN < d.budget && d.freeAfter == 0,
            "spawn: fewer free slots than the budget allows");
        _mark(cv, v.spN == 0 && d.budget > 0 && d.freeAfter == 0, "spawn: no free slot at all, nothing created");
        _mark(cv, v.spN >= 2 && v.sp[0].portalType != v.sp[1].portalType && v.sp[0].nameIndex != v.sp[1].nameIndex
            && v.rp[v.sp[0].slot].hoursToCollapse != v.rp[v.sp[1].slot].hoursToCollapse,
            "spawn: two in one call differ in type, hours and name");
        if (v.spN > 0) {
            uint256 epoch = uint256(v.sp[0].atHour) / uint256(c.epochHours);
            _mark(cv, epoch < uint256(v.stored), "spawn: the hour's epoch is pinned by the old word");
            _mark(cv, epoch >= uint256(v.stored), "spawn: the hour's epoch is pinned by the new word");
            _mark(cv, _differsOnWordSwap(v, cfgs, tps), "spawn: the old and the new word differ, and the result shows it");
        }
        for (uint8 k = 0; k < v.spN; k++) {
            PortalTypeParams memory tp = tps[uint256(v.ts) * 5 + uint8(v.sp[k].portalType)];
            _mark(cv, tp.hoursMin == tp.hoursMax && v.rp[v.sp[k].slot].hoursToCollapse == tp.hoursMin,
                "spawn: hoursMin == hoursMax, the span is one");
            _mark(cv, v.sp[k].nameIndex == 0, "spawn: nameIndex 0");
            _mark(cv, v.sp[k].nameIndex == 23, "spawn: nameIndex 23");
        }
        _mark(cv, v.rg.finished && v.spN > 0, "spawn: created in the death branch");
        _mark(cv, !v.rg.finished && v.spN > 0, "spawn: created in the survival branch");
    }

    function _tagRefusal(Cov memory cv, Vec memory v) private pure {
        bool panic = keccak256(bytes(v.err)) == keccak256(bytes("Panic(0x11)"));
        _mark(cv, panic && v.nowTs < v.g.lastTickAt, "refusal: a stale clock underflows the fill-hour search");
        _mark(cv, panic && v.g.rngNonce == U32_MAX, "refusal: rngNonce at the uint32 ceiling");
        _mark(cv, panic && v.g.rngNonce != U32_MAX && v.g.spawnCount == U32_MAX,
            "refusal: spawnCount at the uint32 ceiling");
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

    function _write(Vec[] memory vs, uint256 n, bool refusal) private {
        for (uint256 i = 0; i < n; i++) {
            // Each line builds hundreds of throw-away strings and EVM memory is
            // never freed; rewinding the free-memory pointer after the write keeps
            // the run inside Foundry's memory cap. Nothing built inside the
            // iteration is used after it. (Same idiom as GenCatchUpVectors.)
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _line(vs[i], i + 1 == n, refusal));
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

    function _eventsJson(TimeLib.Collapse[12] memory ev, uint8 n) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < n; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.collapseJson(ev[i]));
        }
        s = string.concat(s, "]");
    }

    function _spawnsJson(TimeLib.Spawn[12] memory sp, uint8 n) private pure returns (string memory s) {
        s = "[";
        for (uint256 i = 0; i < n; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.spawnJson(sp[i]));
        }
        s = string.concat(s, "]");
    }

    function _line(Vec memory v, bool last, bool refusal) private pure returns (string memory) {
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
            VectorCodec.kv("storedCoveredEpochs", v.stored), ",",
            VectorCodec.kv("maxCoveredEpochs", v.maxCov), ",",
            VectorCodec.kv("nowTs", v.nowTs), ","
        );
        string memory expected = refusal
            ? string.concat('"expected":{', VectorCodec.kb("reverted", v.reverted), ',"error":"', v.err, '"}}')
            : string.concat(
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
