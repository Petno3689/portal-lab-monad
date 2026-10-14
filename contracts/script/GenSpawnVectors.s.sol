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
    MAX_CATCHUP_EVENTS,
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
///   a counter at its uint32 ceiling it panics. Those rows prove the mirror falls
///   over in the same place and the same way, instead of inventing an answer.
///   (A clock behind `lastTickAt` is NOT a refusal any more: `catchUp` clamps it,
///   and those rows are ordinary vectors, each asserted equal to the call at
///   `lastTickAt` at generation time.)
///
/// Coverage: every required case is registered by name (`_register`) and marked by
/// the vectors that reach it; the run ABORTS if any case is reached by none.
contract GenSpawnVectors is Script {
    string private constant PATH = "../shared/test/vectors/spawn-vectors.json";

    uint256 private constant CAPACITY = 80;
    uint256 private constant REFUSALS = 2;
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
        TimeLib.Collapse[64] ev;
        uint8 evN;
        TimeLib.Spawn[64] sp;
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
        uint256 hEnd; // last hour the walk may reach: hNow, or the pinned edge
        uint256 openStart;
        uint256 freeAfter;
        uint256 births;
        bool tailDeath; // died beyond the pinned edge (the deterministic §5.5 overflow)
        bool fuse; // the event fuse stopped the walk
        uint256 fullRaw; // debt0 + pressure over the whole window
        uint256 covered; // debt0 + pressure over the walked span
        uint256 debtAtEdge; // what the births left of `covered`
        uint256 tailNeeded; // pressure that would fill the lab from the edge
        uint256 tailFill; // the hour it would (max when it would not by hNow)
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
            _requireStaleEqualsTick(vs[i], cfgs, tps);
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
    ///       10000 per portal, overflow 5/h, epochHours 12;
    ///   1 — 10000 pressure/h flat: exactly one portal's worth per game hour,
    ///       which makes every fill hour in the comments checkable by eye;
    ///   2 — as 1, overflow OFF (the §5.5 death branch is never considered);
    ///   3 — as 1, spawnCostUnits 0 (`needed` collapses to zero);
    ///   4 — as 1, secPerHour 1 and epochHours 1 (an epoch per game hour, so the
    ///       old/new word split is easy to place);
    ///   5 — as 1, 1e9 pressure/h (saturates spawnDebt at SPAWN_DEBT_MAX);
    ///   6 — as 1, 100 pressure/h (pressure accrues but buys nothing);
    ///   7 — as 1, 5000 pressure/h: a portal matures every second hour, so a birth
    ///       held back by a full lab is visibly later than its maturity.
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

        cfgs[7].basePressurePerHour = 5000;
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
        n = _dStale(vs, n);
        return n;
    }

    // Group A — deaths. Config 1 makes every number readable: pressure is 10000
    // per game hour and a portal costs 10000, so the k-th birth of an empty lab
    // matures at hour k and the lab is full at hour 12. Type set 1 (every type
    // lives exactly twenty hours) keeps the newborns from collapsing before hour
    // 21 where a vector wants only the overflow.
    function _dDeath(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Births fill the lab at hour 12; overflow 5/h kills 5 hp at hour 13,
        // inside the window (hNow 20). No separate branch: it is the walk itself.
        Game memory g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: births fill the lab and the overflow kills inside the window", g, 1, 1, 1, 2, _tsOf(20, SPH));

        // Nothing pinned (maxCovered 0): the world cannot be walked, yet the debt
        // ALONE already fills the lab, so the overflow beyond the edge starts at
        // the edge itself — windowStart 4, not 0, so a mirror that confuses the two
        // is caught.
        g = _g();
        g.hp = 5;
        g.spawnDebt = 120_000;
        g.lastTickAt = _tsOf(4, SPH);
        g.hoursElapsed = 4;
        n = _add(vs, n, "death: beyond the edge, the debt alone fills the lab at the edge", g, 1, 0, 1, 0, _tsOf(10, SPH));

        // Beyond the edge with nothing pinned: the lab would fill at hour 12 and
        // die at 13 == hNow exactly. The bound is not strict, so this still dies.
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: beyond the edge, the hour of death lands exactly on hNow", g, 1, 0, 1, 0, _tsOf(13, SPH));

        // The walk stops at the pinned edge (hour 11) with eleven newborns; the
        // twelfth would mature at hour 12, past the edge. The overflow beyond the
        // edge needs no word, so the edge does not hold the death back (hour 13).
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: the walk stops at the edge and the overflow beyond it kills", g, 1, 1, 1, 1, _tsOf(30, SPH));

        // Twelve already open, hNow inside the pinned span: the overflow drains in
        // the walk itself and 100 hp outlast two hours.
        g = _g();
        g.hp = 100;
        n = _add(vs, n, "death: twelve open, the overflow drains inside the window", g, 1, 0, 1, 1, _tsOf(2, SPH));
        _fill(vs, n, 12);

        // Twelve already open and the clock far past the edge (hour 11): the rule
        // beyond the edge fills a lab, it does not drain a full one, so it is not
        // considered and the run survives at the edge (hp 100 - 11 * 5 = 45).
        g = _g();
        g.hp = 100;
        n = _add(vs, n, "death: not considered beyond the edge, twelve are open there", g, 1, 0, 1, 1, _tsOf(60, SPH));
        _fill(vs, n, 12);

        // Overflow off, the clock past the edge: a full lab costs nothing, so there
        // is nothing to die of beyond it.
        n = _add(vs, n, "death: not considered, hpOverflowPerHour is zero", _g(), 2, 1, 1, 1, _tsOf(20, SPH));

        // A portal that costs nothing: no birth is ever made (it would be endless),
        // and beyond the edge `needed` is zero, so the abandoned lab dies.
        g = _g();
        g.hp = 10;
        n = _add(vs, n, "death: spawnCostUnits zero makes needed zero, and nothing spawns", g, 3, 0, 1, 0, _tsOf(10, SPH));

        // Pressure of 1e9 per hour: twelve births at hour 1, death at hour 2, and
        // the debt left at death saturates at SPAWN_DEBT_MAX.
        g = _g();
        g.hp = 5;
        n = _add(vs, n, "death: the debt saturates at SPAWN_DEBT_MAX", g, 5, 1, 1, 1, _tsOf(5, SPH));

        // One portal's worth of debt and almost no pressure (config 6): one birth
        // at hour 0, which lives twenty hours and collapses with its creatures,
        // costing more than 25 hp. The run dies at hour 20, killed by a portal born
        // inside the same window.
        g = _g();
        g.hp = 25;
        g.spawnDebt = 10_000;
        n = _add(vs, n, "death: a portal born in the window collapses and kills", g, 6, 1, 1, 3, _tsOf(30, SPH));
        return n;
    }

    // Group B — the survival branch: what the debt does when nobody dies.
    function _dSurvive(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // The lab fills at hour 12 and 100 hp buy 20 more hours, so the run is
        // alive at hNow (20) with 60 hp.
        n = _add(vs, n, "survive: the lab fills but the death falls past the window", _g(), 1, 1, 1, 2, _tsOf(20, SPH));

        // Debt 110000: eleven births at hour 0, the twelfth matures at hour 1 ==
        // hNow.
        Game memory g = _g();
        g.spawnDebt = 110_000;
        n = _add(vs, n, "survive: the lab fills only at hNow", g, 1, 1, 1, 1, _tsOf(1, SPH));

        // 100 units an hour for ten hours: the debt grows and still buys nothing.
        n = _add(vs, n, "survive: the debt accrues, no portal affordable yet", _g(), 6, 0, 1, 1, _tsOf(10, SPH));

        // 1e9 an hour for five hours: twelve births at hour 1, then the debt
        // saturates at SPAWN_DEBT_MAX; 100 hp outlast four overflow hours.
        n = _add(vs, n, "survive: the debt saturates at SPAWN_DEBT_MAX", _g(), 5, 1, 1, 1, _tsOf(5, SPH));

        // Capped short: hNow is 30, the pinned edge is hour 11. Only the covered
        // span accrues (1100), never the full window's 3000 — the tail waits for
        // a word.
        n = _add(vs, n, "survive: the debt accrues over the covered span only", _g(), 6, 0, 1, 1, _tsOf(30, SPH));

        // Capped short at hour 11 with eleven newborns: beyond the edge the lab
        // would fill at hour 12, but 100 hp hold until hour 32 > hNow (20).
        n = _add(vs, n, "survive: the lab would fill beyond the edge, the death is past hNow", _g(), 1, 1, 1, 1, _tsOf(20, SPH));
        return n;
    }

    // Group C — how many portals appear, and when.
    function _dSpawns(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // One hour of pressure buys exactly one portal, born at hour 1.
        n = _add(vs, n, "spawn: exactly one portal", _g(), 1, 0, 1, 1, _tsOf(1, SPH));

        // A full lab holds back a matured birth: config 7 matures a portal at hour
        // 2, but all twelve slots are taken until slot 0 collapses at hour 5 — the
        // birth happens then, at the collapse, not at maturity and not at the call.
        n = _add(vs, n, "spawn: a matured birth waits for a full lab to free a slot", _g(), 7, 0, 1, 1, _tsOf(7, SPH));
        _fill(vs, n, 12);
        vs[n - 1].p[0] = _open(5);

        // Eleven slots taken: hour 1 fills the twelfth, the birth maturing at
        // hour 2 finds no room and its pressure stays in the debt.
        n = _add(vs, n, "spawn: fewer free slots than the pressure would buy", _g(), 1, 0, 1, 1, _tsOf(2, SPH));
        _fill(vs, n, 11);

        // A collapse at hour 1 frees slot 0, and the birth maturing at the same
        // hour takes it — collapses first at an equal hour.
        n = _add(vs, n, "spawn: a collapse frees a slot and the birth of the same hour takes it", _g(), 1, 0, 1, 1, _tsOf(2, SPH));
        vs[n - 1].p[0] = _open(1);

        // Every type lives exactly twenty hours: span one, and the hours draw
        // cannot move the result.
        n = _add(vs, n, "spawn: hoursMin == hoursMax, the span is one", _g(), 1, 1, 1, 1, _tsOf(2, SPH));

        // The span is the whole uint16 range: the modulo is wide and the cast to
        // uint16 is exercised at its limit.
        n = _add(vs, n, "spawn: a life span spanning the whole uint16 range", _g(), 1, 2, 1, 1, _tsOf(2, SPH));

        // The canonical config: a ramped pressure (1000 + 1 per lived hour) over a
        // long absence, ending in death. Nothing contrived — this is the shape a
        // real abandoned lab has.
        Game memory g = _g();
        g.hp = 20;
        n = _add(vs, n, "spawn: the deployed config over a long absence", g, 0, 0, 1, 30, _tsOf(200, SPH));

        // One portal's worth of debt, almost no pressure: born at hour 0, collapses
        // at hour 20 inside the window, and 100 hp survive it.
        g = _g();
        g.spawnDebt = 10_000;
        n = _add(vs, n, "spawn: a portal born in the window collapses in the window", g, 6, 1, 1, 3, _tsOf(30, SPH));

        // The starting hand: three portals' worth of debt, called at the very hour
        // the game began — all three are born at hour 0.
        g = _g();
        g.spawnDebt = 30_000;
        n = _add(vs, n, "spawn: the starting hand, born at the window start", g, 0, 0, 1, 1, _tsOf(0, SPH));

        // The event fuse: 1e9 pressure an hour fills the lab at hour 1, every
        // newborn collapses twenty hours later and is replaced at once. Sixty-four
        // events are spent by hour 61; the walk stops there and reports it like the
        // pinned edge. 60000 hp keep the run alive throughout.
        g = _g();
        g.hp = 60_000;
        n = _add(vs, n, "fuse: sixty-four events stop the walk at the last one", g, 5, 1, 1, 100, _tsOf(400, SPH));
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

    /// @dev The one-spawn probe world: config 1 (one portal's worth an hour), the
    /// canonical types, an empty lab, ONE lived hour so exactly one portal is born,
    /// nothing pinned (`stored` 0) so the NEW word is the one that pins epoch 0 and
    /// the hunt has something to vary.
    function _probeName(Config[] memory cfgs, PortalTypeParams[] memory tps, uint256 word)
        private
        pure
        returns (uint8 spN, uint16 nameIndex)
    {
        Game memory g = _g();
        Portal[12] memory p;
        TimeLib.Spawn[64] memory sp;
        (,,,, sp, spN,) = TimeLib.catchUp(g, p, cfgs[1], _set(tps, 0), OLD_WORD, word, 0, 1, _tsOf(1, SPH));
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
            1,
            0,
            0,
            1,
            _tsOf(1, SPH)
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
        (, Portal[12] memory rp,,, TimeLib.Spawn[64] memory sp, uint8 spN,) =
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

    // Group F — a stale clock (`nowTs` behind `lastTickAt`). catchUp clamps the
    // clock, so these are ordinary vectors; `_requireStaleEqualsTick` proves at
    // generation time that each equals the same call at `lastTickAt`.
    function _dStale(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Empty lab, needed 120000, debt 150000, the clock five hours behind.
        Game memory g = _g();
        g.spawnDebt = 150_000;
        g.lastTickAt = _tsOf(10, SPH);
        g.hoursElapsed = 10;
        n = _add(vs, n, "stale clock: five hours behind, debt above needed", g, 1, 0, 1, 2, _tsOf(5, SPH));

        // Half the lab occupied (needed 60000) and the debt exactly meeting it:
        // the condition is reached by equality, not by a wide margin.
        g = _g();
        g.spawnDebt = 60_000;
        g.lastTickAt = _tsOf(20, SPH);
        g.hoursElapsed = 20;
        n = _add(vs, n, "stale clock: the debt meeting needed exactly", g, 1, 0, 1, 2, _tsOf(3, SPH));
        _fill(vs, n, 6);

        // The same staleness one second before the window start, under config 4
        // (one second per game hour), where a single second of staleness is a
        // whole game hour.
        g = _g();
        g.spawnDebt = 120_000;
        g.lastTickAt = _tsOf(9, 1);
        g.hoursElapsed = 9;
        n = _add(vs, n, "stale clock: behind by a single game hour", g, 4, 0, 1, 20, _tsOf(8, 1));

        return n;
    }

    // ── refusal vectors ─────────────────────────────────────────────────────

    /// @dev `catchUp` is not total. Every row here is a reachable input on which
    /// the contract PANICS, recorded so both replayers can prove they fall over in
    /// the same place and the same way: the per-spawn counters at their uint32
    /// ceiling. The next spawn increments `rngNonce`, then `spawnCount`, and a
    /// `uint32` at its maximum cannot take the increment.
    function _refusals(Vec[] memory rf, uint256 n) private pure returns (uint256) {
        Game memory g;
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
            TimeLib.Collapse[64] memory ev,
            uint8 evN,
            TimeLib.Spawn[64] memory sp,
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

    /// @dev A stale clock must give exactly the result of the call at `lastTickAt`.
    function _requireStaleEqualsTick(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps)
        private
        pure
    {
        if (v.nowTs >= v.g.lastTickAt) return;
        bytes memory a = _run(v, cfgs, tps, v.nowTs);
        bytes memory b = _run(v, cfgs, tps, v.g.lastTickAt);
        require(keccak256(a) == keccak256(b), string.concat("stale clock differs from lastTickAt: ", v.label));
    }

    function _run(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps, uint40 ts)
        private
        pure
        returns (bytes memory)
    {
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
        ) = TimeLib.catchUp(gIn, pIn, cfgs[v.cfg], _set(tps, v.ts), v.oldWord, v.newWord, v.stored, v.maxCov, ts);
        return abi.encode(rg, rp, ev, evN, sp, spN, capped);
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

        _reg(cv, "death: births fill the lab and the overflow kills inside the window");
        _reg(cv, "death: a portal born in the window collapses and kills");
        _reg(cv, "death: beyond the edge, the abandoned lab overflows; no portal is born there");
        _reg(cv, "death: beyond the edge, hFill lands exactly on the edge");
        _reg(cv, "death: beyond the edge, the hour of death equals hNow (the bound is not strict)");
        _reg(cv, "death: not considered beyond the edge, twelve are open there");
        _reg(cv, "death: not considered beyond the edge, hpOverflowPerHour == 0");
        _reg(cv, "death: spawnCostUnits == 0 makes needed zero, the run dies, nothing spawns");
        _reg(cv, "death: spawnDebt saturates at SPAWN_DEBT_MAX");

        _reg(cv, "survive: the debt accrues, no portal affordable yet");
        _reg(cv, "survive: spawnDebt saturates at SPAWN_DEBT_MAX");
        _reg(cv, "survive: the debt accrues over the covered span only, the tail is left");
        _reg(cv, "survive: the lab would fill beyond the edge, but the death falls past hNow");

        _reg(cv, "spawn: exactly one portal created");
        _reg(cv, "spawn: births at different hours in one window");
        _reg(cv, "spawn: a birth lands at its maturity, before the end of the window");
        _reg(cv, "spawn: a matured birth waits for a full lab to free a slot");
        _reg(cv, "spawn: a portal born in the window collapses in the window");
        _reg(cv, "spawn: the debt alone births at the window start");
        _reg(cv, "spawn: fewer free slots than the pressure would buy");
        _reg(cv, "spawn: no free slot at all, nothing created");
        _reg(cv, "spawn: two in one call differ in type, hours and name");
        _reg(cv, "spawn: the hour's epoch is pinned by the old word");
        _reg(cv, "spawn: the hour's epoch is pinned by the new word");
        _reg(cv, "spawn: the old and the new word differ, and the result shows it");
        _reg(cv, "spawn: hoursMin == hoursMax, the span is one");
        _reg(cv, "spawn: nameIndex 0");
        _reg(cv, "spawn: nameIndex 23");
        _reg(cv, "spawn: created in a run that died");
        _reg(cv, "spawn: created in a run that survived");

        _reg(cv, "fuse: the event cap stops the walk, reported as cappedShort");

        _reg(cv, "stale clock: equals the call at lastTickAt");
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

    /// @dev Smallest hour in `[lo, hi]` where `have + spawnPressure(from, h)`
    /// reaches `target`, by plain binary search, recomputed for the coverage
    /// names ONLY (so a case can say "hFill lands on the edge" rather than describe
    /// a timestamp). Nothing recorded in the file depends on it.
    function _firstHourTag(uint256 from, uint256 lo, uint256 hi, uint256 have, uint256 target, Config memory c)
        private
        pure
        returns (uint256)
    {
        for (uint256 it = 0; it < 64 && lo < hi; it++) {
            uint256 mid = (lo + hi) / 2;
            if (have + TimeLib.spawnPressure(from, mid, c) >= target) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    function _derive(Vec memory v, Config memory c) private pure returns (Derived memory d) {
        d.sph = c.secPerHour;
        uint256 nowEff = v.nowTs < v.g.lastTickAt ? v.g.lastTickAt : v.nowTs; // catchUp clamps a stale clock
        d.hNow = (uint256(nowEff) - uint256(v.g.startedAt)) / d.sph;
        d.windowStart = (uint256(v.g.lastTickAt) - uint256(v.g.startedAt)) / d.sph;
        uint256 edge = v.maxCov == 0 ? d.windowStart : uint256(v.maxCov) * uint256(c.epochHours) - 1;
        if (edge < d.windowStart) edge = d.windowStart;
        d.hEnd = d.hNow < edge ? d.hNow : edge;
        for (uint256 i = 0; i < 12; i++) {
            if (v.p[i].status != PortalStatus.Empty) d.openStart += 1;
            if (v.rp[i].status == PortalStatus.Empty) d.freeAfter += 1;
        }
        d.births = v.spN;
        d.tailDeath = v.rg.finished && uint256(v.rg.diedAtHour) > d.hEnd;
        d.fuse = !v.rg.finished && v.cappedShort && uint256(v.evN) + uint256(v.spN) == MAX_CATCHUP_EVENTS;
        d.fullRaw = uint256(v.g.spawnDebt) + TimeLib.spawnPressure(d.windowStart, d.hNow, c);
        d.covered = uint256(v.g.spawnDebt) + TimeLib.spawnPressure(d.windowStart, d.hEnd, c);
        // The state the walk handed to the overflow beyond the edge: the debt left
        // at the edge and the portals open there (a tail death freezes the world at
        // the edge, so `rp` IS that state).
        uint256 spent = d.births * uint256(c.spawnCostUnits);
        d.debtAtEdge = d.covered > spent ? d.covered - spent : 0;
        uint256 openAtEdge = 12 - d.freeAfter;
        d.tailNeeded = (MAX_OPEN_PORTALS - openAtEdge) * uint256(c.spawnCostUnits);
        d.tailFill = d.debtAtEdge + TimeLib.spawnPressure(d.hEnd, d.hNow, c) >= d.tailNeeded
            ? _firstHourTag(d.hEnd, d.hEnd, d.hNow, d.debtAtEdge, d.tailNeeded, c)
            : type(uint256).max;
    }

    /// @dev Pressure available at hour `h` of the window: `debt0 + P(windowStart, h)`.
    function _avail(Vec memory v, Derived memory d, Config memory c, uint256 h) private pure returns (uint256) {
        return uint256(v.g.spawnDebt) + TimeLib.spawnPressure(d.windowStart, h, c);
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
        (, Portal[12] memory rp2,,, TimeLib.Spawn[64] memory sp2, uint8 n2,) = TimeLib.catchUp(
            gIn, pIn, cfgs[v.cfg], _set(tps, v.ts), v.newWord, v.oldWord, v.stored, v.maxCov, v.nowTs
        );
        if (n2 != v.spN) return true;
        uint8 s = v.sp[0].slot;
        return sp2[0].portalType != v.sp[0].portalType || sp2[0].nameIndex != v.sp[0].nameIndex
            || rp2[s].hoursToCollapse != v.rp[s].hoursToCollapse;
    }

    function _tag(Cov memory cv, Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps) private pure {
        Config memory c = cfgs[v.cfg];
        if (v.g.startedAt == 0 || v.g.finished || v.nowTs < v.g.startedAt) return; // nothing is walked
        _mark(cv, v.nowTs < v.g.lastTickAt, "stale clock: equals the call at lastTickAt");
        Derived memory d = _derive(v, c);
        bool walkDeath = v.rg.finished && !d.tailDeath;

        _mark(cv, walkDeath && v.spN > 0 && v.rg.openPortals == MAX_OPEN_PORTALS && v.evN == 0,
            "death: births fill the lab and the overflow kills inside the window");
        _mark(cv, walkDeath && v.evN > 0 && _bornThenCollapsed(v, v.evN - 1),
            "death: a portal born in the window collapses and kills");
        _mark(cv, d.tailDeath && uint256(v.rg.diedAtHour) <= d.hNow
            && (v.spN == 0 || uint256(v.sp[v.spN - 1].atHour) <= d.hEnd),
            "death: beyond the edge, the abandoned lab overflows; no portal is born there");
        _mark(cv, d.tailDeath && d.tailFill == d.hEnd, "death: beyond the edge, hFill lands exactly on the edge");
        _mark(cv, d.tailDeath && uint256(v.rg.diedAtHour) == d.hNow,
            "death: beyond the edge, the hour of death equals hNow (the bound is not strict)");
        _mark(cv, !v.rg.finished && v.cappedShort && !d.fuse && d.freeAfter == 0 && c.hpOverflowPerHour > 0,
            "death: not considered beyond the edge, twelve are open there");
        _mark(cv, c.hpOverflowPerHour == 0 && v.cappedShort && !v.rg.finished && d.tailFill != type(uint256).max,
            "death: not considered beyond the edge, hpOverflowPerHour == 0");
        _mark(cv, c.spawnCostUnits == 0 && v.rg.finished && v.spN == 0 && v.evN == 0,
            "death: spawnCostUnits == 0 makes needed zero, the run dies, nothing spawns");
        _mark(cv, v.rg.finished && uint256(v.rg.spawnDebt) == SPAWN_DEBT_MAX, "death: spawnDebt saturates at SPAWN_DEBT_MAX");

        _mark(cv, !v.rg.finished && v.spN == 0 && v.rg.spawnDebt > v.g.spawnDebt
            && uint256(v.rg.spawnDebt) < uint256(c.spawnCostUnits),
            "survive: the debt accrues, no portal affordable yet");
        _mark(cv, !v.rg.finished && uint256(v.rg.spawnDebt) == SPAWN_DEBT_MAX, "survive: spawnDebt saturates at SPAWN_DEBT_MAX");
        _mark(cv, !v.rg.finished && v.cappedShort && !d.fuse && d.covered < d.fullRaw
            && uint256(v.rg.spawnDebt) == d.debtAtEdge,
            "survive: the debt accrues over the covered span only, the tail is left");
        _mark(cv, !v.rg.finished && v.cappedShort && !d.fuse && c.hpOverflowPerHour > 0
            && d.tailFill != type(uint256).max,
            "survive: the lab would fill beyond the edge, but the death falls past hNow");

        _mark(cv, d.fuse && uint256(v.rg.hoursElapsed) < d.hEnd,
            "fuse: the event cap stops the walk, reported as cappedShort");

        _tagSpawns(cv, v, c, d, cfgs, tps);
    }

    /// @dev True when collapse record `j` struck a portal that was born in this
    /// window: the same slot took a birth strictly before the collapse hour (a
    /// stored portal's collapse in a slot later refilled is at or before the birth).
    function _bornThenCollapsed(Vec memory v, uint256 j) private pure returns (bool) {
        for (uint256 k = 0; k < v.spN; k++) {
            if (v.sp[k].slot == v.ev[j].slot && v.sp[k].atHour < v.ev[j].atHour) return true;
        }
        return false;
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
        _mark(cv, v.spN >= 2 && v.sp[0].atHour != v.sp[v.spN - 1].atHour, "spawn: births at different hours in one window");
        bool beforeEnd = false;
        bool delayed = false;
        for (uint8 k = 0; k < v.spN; k++) {
            uint256 at = v.sp[k].atHour;
            if (at < d.hEnd) beforeEnd = true;
            // Matured an hour or more earlier, yet born only now: a full lab held it.
            if (at > d.windowStart && _avail(v, d, c, at - 1) >= (uint256(k) + 1) * uint256(c.spawnCostUnits)) {
                delayed = true;
            }
        }
        _mark(cv, beforeEnd, "spawn: a birth lands at its maturity, before the end of the window");
        _mark(cv, delayed, "spawn: a matured birth waits for a full lab to free a slot");
        bool bornCollapsed = false;
        for (uint256 j = 0; j < v.evN; j++) {
            if (_bornThenCollapsed(v, j)) bornCollapsed = true;
        }
        _mark(cv, bornCollapsed, "spawn: a portal born in the window collapses in the window");
        _mark(cv, v.spN > 0 && uint256(v.sp[0].atHour) == d.windowStart && v.g.spawnDebt >= c.spawnCostUnits,
            "spawn: the debt alone births at the window start");
        _mark(cv, v.spN > 0 && d.freeAfter == 0 && !v.rg.finished && v.rg.spawnDebt >= c.spawnCostUnits,
            "spawn: fewer free slots than the pressure would buy");
        _mark(cv, v.spN == 0 && v.evN == 0 && d.openStart == MAX_OPEN_PORTALS && c.spawnCostUnits > 0
            && v.rg.spawnDebt >= c.spawnCostUnits, "spawn: no free slot at all, nothing created");
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
            _mark(cv, tp.hoursMin == tp.hoursMax && tp.hoursMin > 0, "spawn: hoursMin == hoursMax, the span is one");
            _mark(cv, v.sp[k].nameIndex == 0, "spawn: nameIndex 0");
            _mark(cv, v.sp[k].nameIndex == 23, "spawn: nameIndex 23");
        }
        _mark(cv, v.rg.finished && v.spN > 0, "spawn: created in a run that died");
        _mark(cv, !v.rg.finished && v.spN > 0, "spawn: created in a run that survived");
    }

    function _tagRefusal(Cov memory cv, Vec memory v) private pure {
        bool panic = keccak256(bytes(v.err)) == keccak256(bytes("Panic(0x11)"));
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
