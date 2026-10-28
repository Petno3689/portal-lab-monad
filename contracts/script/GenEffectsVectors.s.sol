// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EffectsLib} from "../src/EffectsLib.sol";
import {RandomStub} from "../src/RandomStub.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {
    Game,
    Portal,
    Config,
    PortalTypeParams,
    PortalType,
    PortalStatus,
    Action
} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";
import {EffectsHarness} from "../test/utils/EffectsHarness.sol";

/// @notice Generates the golden vectors for the EffectsLib TS mirror:
///   ../shared/test/vectors/effects-vectors.json
/// Run from contracts/:  forge script script/GenEffectsVectors.s.sol
/// No RPC, no broadcast. The file format (incl. the revert extension) is documented
/// in shared/test/support/vectorFormat.ts.
///
/// Each vector is run through the REAL library (via EffectsHarness, so reverts are
/// catchable and inputs cannot be mutated) and the FULL state after the call is
/// recorded — never a delta, so a field that should have changed and did not is
/// visible. A call that reverts is recorded as a revert with the error's name.
///
/// The set is a modest RANDOM part (deterministic: keccak of a tag and the index)
/// PLUS a large DIRECTED part. Random alone never reaches the interesting branches
/// of a nine-way dispatcher with short bodies (a clamp at 100, a blind evacuation
/// of the last creature, a close at hp == loss, the Deaf narrowedOnce flag), so
/// each is built on purpose. `run` aborts unless every entry of the coverage list
/// (`_register`) is hit by at least one vector — if you add a branch to EffectsLib,
/// add a tag and a directed vector.
///
/// If the file outgrows ~2 MB, cut the RANDOM_* counts, never the directed block.
contract GenEffectsVectors is Script {
    uint256 private constant RANDOM_APPLY = 280;
    uint256 private constant RANDOM_SURVEY = 80;
    uint256 private constant RANDOM_REVEAL = 40;
    uint256 private constant CAPACITY = 900;
    uint256 private constant CONFIG_COUNT = 4;
    uint256 private constant TP_COUNT = 10;
    string private constant PATH = "../shared/test/vectors/effects-vectors.json";

    uint256 private constant MAX32 = 4294967295;

    struct Vec {
        string label;
        Game g;
        Portal p;
        uint8 cfg;
        uint8 tp;
        Action a;
        uint256 word;
        // result, filled by _eval
        bool reverted;
        string err;
        Game rg;
        Portal rp;
        EffectsLib.Outcome ro;
        bool precise;
    }

    /// @dev Coverage registry: a fixed list of tag names and a hit counter each.
    struct Cov {
        string[] names;
        uint256[] counts;
        uint256 n;
    }

    function run() external {
        Config[] memory cfgs = _configs();
        PortalTypeParams[] memory tps = _typeParams();
        EffectsHarness h = new EffectsHarness();

        Vec[] memory ap = new Vec[](CAPACITY);
        Vec[] memory sv = new Vec[](CAPACITY);
        Vec[] memory rv = new Vec[](CAPACITY);
        uint256 nAp = _directedApply(ap, 0);
        uint256 nSv = _directedSurvey(sv, 0);
        uint256 nRv = _directedReveal(rv, 0);
        uint256 directed = nAp + nSv + nRv;
        nAp = _randomApply(ap, nAp);
        nSv = _randomSurvey(sv, nSv);
        nRv = _randomReveal(rv, nRv);

        Cov memory cv = _register();
        for (uint256 i = 0; i < nAp; i++) {
            _evalApply(ap[i], cfgs, tps, h);
            _tagApply(cv, ap[i], cfgs[ap[i].cfg], tps[ap[i].tp]);
        }
        for (uint256 i = 0; i < nSv; i++) {
            _evalSurvey(sv[i], cfgs, tps, h);
            _tagSurvey(cv, sv[i], cfgs[sv[i].cfg], tps[sv[i].tp]);
        }
        for (uint256 i = 0; i < nRv; i++) {
            _evalReveal(rv[i], cfgs, h);
            _tagReveal(cv, rv[i], cfgs[rv[i].cfg]);
        }
        _requireCoverage(cv);

        vm.writeFile(PATH, _head(cfgs, tps));
        _writeGroup(ap, nAp, 0);
        vm.writeLine(PATH, '],"survey":[');
        _writeGroup(sv, nSv, 1);
        vm.writeLine(PATH, '],"blindReveal":[');
        _writeGroup(rv, nRv, 2);
        vm.writeLine(PATH, "]}");

        console.log("effects vectors written (applyAction / survey / blindReveal):", nAp, nSv, nRv);
        console.log("  directed:", directed);
        console.log("  random:", nAp + nSv + nRv - directed);
        console.log("coverage (hits per tag):");
        for (uint256 i = 0; i < cv.n; i++) {
            console.log(string.concat("  ", vm.toString(cv.counts[i]), "  ", cv.names[i]));
        }
    }

    // ── configs and type parameters ──────────────────────────────────────────

    /// @dev Four configs, each built fresh (memory structs are references).
    ///   0 — the deployed GameConfig (heal 3, hpMax 100, 10 HP per death);
    ///   1 — heal 40, 1000 HP per death (loss overflows uint16), cooldown 65535;
    ///   2 — hpMax and heal 65535, bonus uint32 max, cooldown 0;
    ///   3 — nothing heals or hurts, bonus 0, cooldown 3.
    function _configs() private pure returns (Config[] memory cfgs) {
        cfgs = new Config[](CONFIG_COUNT);
        cfgs[0] = GameConfig.config();

        Config memory c1 = GameConfig.config();
        c1.healPerCreature = 40;
        c1.hpCollapsePerDeath = 1000;
        c1.rescuerCooldownHours = 65535;
        c1.closePressureBonus = 1;
        cfgs[1] = c1;

        Config memory c2 = GameConfig.config();
        c2.hpMax = 65535;
        c2.healPerCreature = 65535;
        c2.hpCollapsePerDeath = 65535;
        c2.closePressureBonus = 4294967295;
        c2.rescuerCooldownHours = 0;
        cfgs[2] = c2;

        Config memory c3 = GameConfig.config();
        c3.healPerCreature = 0;
        c3.hpCollapsePerDeath = 0;
        c3.closePressureBonus = 0;
        c3.rescuerCooldownHours = 3;
        cfgs[3] = c3;
    }

    /// @dev 0–4 are the five canonical type rows (Flash, LongLived, Deaf, Resonant,
    /// Energetic). 5–9 are synthetic, to exercise `25 × mult / 100`:
    ///   5 — 150% (37.5 → 37), deaf;  6 — 30% (7.5 → 7), precise;  7 — 400% (100), deaf;
    ///   8 — 0% (step 0), precise;     9 — 65535% (16383), deaf.
    function _typeParams() private pure returns (PortalTypeParams[] memory tps) {
        tps = new PortalTypeParams[](TP_COUNT);
        PortalTypeParams[5] memory canon = GameConfig.portalTypeParams();
        for (uint256 i = 0; i < 5; i++) {
            tps[i] = canon[i];
        }
        tps[5] = _tpVariant(150, false);
        tps[6] = _tpVariant(30, true);
        tps[7] = _tpVariant(400, false);
        tps[8] = _tpVariant(0, true);
        tps[9] = _tpVariant(65535, false);
    }

    function _tpVariant(uint16 mult, bool precise) private pure returns (PortalTypeParams memory t) {
        t = GameConfig.portalTypeParams()[0];
        t.actionMultiplierPct = mult;
        t.surveyPrecise = precise;
    }

    // ── fresh base states (never share a struct between two vectors) ─────────

    function _g() private pure returns (Game memory g) {
        g.startedAt = 1000;
        g.lastTickAt = 1000;
        g.hoursElapsed = 20;
        g.hp = 50;
        g.power = 100;
        g.observersFree = 2;
        g.rescuersFree = 1;
        g.openPortals = 3;
        g.spawnCount = 7;
        g.creaturesRescued = 5;
    }

    /// @dev Open, surveyed, exact numbers, ranges bracketing them, nobody inside.
    function _p() private pure returns (Portal memory p) {
        p.id = 1;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.stability = 50;
        p.energy = 50;
        p.creatures = 3;
        p.hoursToCollapse = 24;
        p.stabilityLo = 40;
        p.stabilityHi = 60;
        p.energyLo = 40;
        p.energyHi = 60;
        p.creaturesLo = 1;
        p.creaturesHi = 5;
    }

    /// @dev An unsurveyed portal: exact fields hold stale values, the ranges are the truth.
    function _unsurveyed() private pure returns (Portal memory p) {
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
    }

    function _addA(
        Vec[] memory vs,
        uint256 n,
        string memory label,
        Game memory g,
        Portal memory p,
        uint8 cfg,
        uint8 tp,
        Action a
    ) private pure returns (uint256) {
        Vec memory v = vs[n];
        v.label = label;
        v.g = g;
        v.p = p;
        v.cfg = cfg;
        v.tp = tp;
        v.a = a;
        return n + 1;
    }

    function _addS(Vec[] memory vs, uint256 n, string memory label, Portal memory p, uint8 cfg, uint8 tp, uint256 word)
        private
        pure
        returns (uint256)
    {
        Vec memory v = vs[n];
        v.label = label;
        v.p = p;
        v.cfg = cfg;
        v.tp = tp;
        v.word = word;
        return n + 1;
    }

    function _addR(Vec[] memory vs, uint256 n, string memory label, Game memory g, Portal memory p, uint8 cfg, uint256 word)
        private
        pure
        returns (uint256)
    {
        Vec memory v = vs[n];
        v.label = label;
        v.g = g;
        v.p = p;
        v.cfg = cfg;
        v.word = word;
        return n + 1;
    }

    // ── directed: applyAction ────────────────────────────────────────────────

    function _directedApply(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        n = _dToggle(vs, n);
        n = _dStabilize(vs, n);
        n = _dDestabilize(vs, n);
        n = _dCrew(vs, n);
        n = _dEvacuate(vs, n);
        n = _dEvacuateRevert(vs, n);
        n = _dClose(vs, n);
        n = _dCloseEdge(vs, n);
        return n;
    }

    function _dToggle(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        n = _addA(vs, n, "toggle: open", _g(), _p(), 0, 0, Action.ToggleQuestioned);
        Portal memory q = _p();
        q.status = PortalStatus.Questioned;
        n = _addA(vs, n, "toggle: questioned", _g(), q, 0, 0, Action.ToggleQuestioned);
        Portal memory e = _p();
        e.status = PortalStatus.Empty;
        n = _addA(vs, n, "toggle: empty slot becomes open (no guard in the library)", _g(), e, 0, 0, Action.ToggleQuestioned);
        return n;
    }

    function _dStabilize(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Default config energy 50, stability 50. Step is 25 (tp 0), 50 (tp 3).
        n = _addA(vs, n, "stabilize: plain", _g(), _p(), 0, 0, Action.Stabilize);
        n = _addA(vs, n, "stabilize: resonant doubles the step", _g(), _p(), 0, 3, Action.Stabilize);

        uint8[5] memory stabs = [uint8(74), 75, 76, 100, 255];
        for (uint256 i = 0; i < stabs.length; i++) {
            Portal memory p = _p();
            p.stability = stabs[i];
            n = _addA(vs, n, "stabilize: ceiling (75 lands on 100, 76 clamps)", _g(), p, 0, 0, Action.Stabilize);
        }
        uint8[4] memory ens = [uint8(0), 9, 10, 11];
        for (uint256 i = 0; i < ens.length; i++) {
            Portal memory p = _p();
            p.energy = ens[i];
            n = _addA(vs, n, "stabilize: energy floor (9 and below clamp, 10 lands on 0)", _g(), p, 0, 0, Action.Stabilize);
        }
        // Truncating strength: tp 5 = 150% (37), tp 6 = 30% (7), tp 7 = 400% (100), tp 8 = 0%, tp 9 = 65535%.
        for (uint8 t = 5; t <= 9; t++) {
            n = _addA(vs, n, "stabilize: synthetic multiplier", _g(), _p(), 0, t, Action.Stabilize);
            Portal memory p = _p();
            p.stability = 0;
            n = _addA(vs, n, "stabilize: synthetic multiplier from zero", _g(), p, 0, t, Action.Stabilize);
        }
        Portal memory x = _p();
        x.stability = 62;
        n = _addA(vs, n, "stabilize: 62 + 37 clamps (tp 5)", _g(), x, 0, 5, Action.Stabilize);
        x = _p();
        x.stability = 63;
        n = _addA(vs, n, "stabilize: 63 + 37 lands on 100 (tp 5)", _g(), x, 0, 5, Action.Stabilize);
        return n;
    }

    function _dDestabilize(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        n = _addA(vs, n, "destabilize: plain", _g(), _p(), 0, 0, Action.Destabilize);
        n = _addA(vs, n, "destabilize: resonant doubles the step", _g(), _p(), 0, 3, Action.Destabilize);

        uint8[6] memory stabs = [uint8(0), 10, 24, 25, 26, 255];
        for (uint256 i = 0; i < stabs.length; i++) {
            Portal memory p = _p();
            p.stability = stabs[i];
            n = _addA(vs, n, "destabilize: floor (25 lands on 0 by the strict test, 26 on 1)", _g(), p, 0, 0, Action.Destabilize);
        }
        uint8[6] memory ens = [uint8(0), 89, 90, 91, 100, 255];
        for (uint256 i = 0; i < ens.length; i++) {
            Portal memory p = _p();
            p.energy = ens[i];
            n = _addA(vs, n, "destabilize: energy ceiling (90 lands on 100, above clamps)", _g(), p, 0, 0, Action.Destabilize);
        }
        for (uint8 t = 5; t <= 9; t++) {
            n = _addA(vs, n, "destabilize: synthetic multiplier", _g(), _p(), 0, t, Action.Destabilize);
        }
        Portal memory x = _p();
        x.stability = 37;
        n = _addA(vs, n, "destabilize: 37 - 37 (tp 5) lands on 0 by the strict test", _g(), x, 0, 5, Action.Destabilize);
        x = _p();
        x.stability = 38;
        n = _addA(vs, n, "destabilize: 38 - 37 (tp 5)", _g(), x, 0, 5, Action.Destabilize);
        return n;
    }

    function _dCrew(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // SendObserver on an already-surveyed portal (the bare placement; the unsurveyed
        // survey is two-phase and never reaches applyAction).
        n = _addA(vs, n, "send observer: surveyed", _g(), _p(), 0, 0, Action.SendObserver);
        Game memory g = _g();
        g.observersFree = 1;
        n = _addA(vs, n, "send observer: last free observer", g, _p(), 0, 0, Action.SendObserver);
        g = _g();
        g.observersFree = 0;
        n = _addA(vs, n, "send observer: none free (checked underflow)", g, _p(), 0, 0, Action.SendObserver);

        Portal memory p = _p();
        p.observerInside = true;
        n = _addA(vs, n, "recall observer", _g(), p, 0, 0, Action.RecallObserver);
        g = _g();
        g.observersFree = 254;
        p = _p();
        p.observerInside = true;
        n = _addA(vs, n, "recall observer: 254 -> 255 fits", g, p, 0, 0, Action.RecallObserver);
        g = _g();
        g.observersFree = 255;
        p = _p();
        p.observerInside = true;
        n = _addA(vs, n, "recall observer: 255 overflows", g, p, 0, 0, Action.RecallObserver);

        // SendRescuer, sighted.
        n = _addA(vs, n, "send rescuer: sighted", _g(), _p(), 0, 0, Action.SendRescuer);
        g = _g();
        g.rescuersFree = 0;
        n = _addA(vs, n, "send rescuer: none free (checked underflow)", g, _p(), 0, 0, Action.SendRescuer);

        p = _p();
        p.rescuerInside = true;
        n = _addA(vs, n, "recall rescuer", _g(), p, 0, 0, Action.RecallRescuer);
        g = _g();
        g.rescuersFree = 254;
        p = _p();
        p.rescuerInside = true;
        n = _addA(vs, n, "recall rescuer: 254 -> 255 fits", g, p, 0, 0, Action.RecallRescuer);
        g = _g();
        g.rescuersFree = 255;
        p = _p();
        p.rescuerInside = true;
        n = _addA(vs, n, "recall rescuer: 255 overflows", g, p, 0, 0, Action.RecallRescuer);
        return n;
    }

    function _evacPortal() private pure returns (Portal memory p) {
        p = _p();
        p.rescuerInside = true;
    }

    function _dEvacuate(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Sighted (surveyed): everyone out. Default heal 3/creature, hpMax 100.
        n = _addA(vs, n, "evacuate: surveyed, 3 creatures", _g(), _evacPortal(), 0, 0, Action.Evacuate);

        Portal memory p = _evacPortal();
        p.creatures = 0;
        n = _addA(vs, n, "evacuate: surveyed, zero creatures", _g(), p, 0, 0, Action.Evacuate);

        // Blind (unsurveyed): one is always left behind.
        p = _evacPortal();
        p.surveyed = false;
        p.creaturesKnown = true;
        n = _addA(vs, n, "evacuate: blind, 3 creatures (one stays)", _g(), p, 0, 0, Action.Evacuate);
        p = _evacPortal();
        p.surveyed = false;
        p.creaturesKnown = true;
        p.creatures = 1;
        n = _addA(vs, n, "evacuate: blind, the last creature saves nobody", _g(), p, 0, 0, Action.Evacuate);
        p = _evacPortal();
        p.surveyed = false;
        p.creaturesKnown = true;
        p.creatures = 0;
        n = _addA(vs, n, "evacuate: blind, zero creatures", _g(), p, 0, 0, Action.Evacuate);
        p = _evacPortal();
        p.surveyed = false;
        p.creaturesKnown = true;
        p.creatures = 255;
        n = _addA(vs, n, "evacuate: blind, 255 creatures", _g(), p, 2, 0, Action.Evacuate);

        // Healing against hpMax (100): 3 creatures = +9.
        uint16[6] memory hps = [uint16(0), 90, 91, 92, 99, 100];
        for (uint256 i = 0; i < hps.length; i++) {
            Game memory g = _g();
            g.hp = hps[i];
            n = _addA(vs, n, "evacuate: heal vs hpMax (91 lands on 100, above clamps)", g, _evacPortal(), 0, 0, Action.Evacuate);
        }
        // Other configs: heal 40/creature; heal 65535 against hpMax 65535; heal 0.
        Game memory g1 = _g();
        g1.hp = 10;
        n = _addA(vs, n, "evacuate: heal 40 per creature, clamps at 100", g1, _evacPortal(), 1, 0, Action.Evacuate);
        Game memory g2 = _g();
        g2.hp = 1000;
        p = _evacPortal();
        p.creatures = 200;
        n = _addA(vs, n, "evacuate: heal beyond hpMax 65535", g2, p, 2, 0, Action.Evacuate);
        n = _addA(vs, n, "evacuate: heals nothing", _g(), _evacPortal(), 3, 0, Action.Evacuate);

        // Counters at their limits (still fit).
        Game memory g3 = _g();
        g3.rescuersFree = 254;
        g3.creaturesRescued = uint32(MAX32 - 3);
        n = _addA(vs, n, "evacuate: rescuersFree 255 and creaturesRescued uint32 max fit", g3, _evacPortal(), 0, 0, Action.Evacuate);
        return n;
    }

    function _dEvacuateRevert(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Game memory g = _g();
        g.rescuersFree = 255;
        n = _addA(vs, n, "evacuate: rescuersFree overflows", g, _evacPortal(), 0, 0, Action.Evacuate);

        g = _g();
        g.hp = 101;
        n = _addA(vs, n, "evacuate: hp above hpMax underflows the gain", g, _evacPortal(), 0, 0, Action.Evacuate);

        g = _g();
        g.hp = 101;
        Portal memory p = _evacPortal();
        p.creatures = 0;
        n = _addA(vs, n, "evacuate: hp above hpMax underflows even with nobody to save", g, p, 0, 0, Action.Evacuate);

        g = _g();
        g.creaturesRescued = uint32(MAX32 - 2);
        n = _addA(vs, n, "evacuate: creaturesRescued overflows uint32", g, _evacPortal(), 0, 0, Action.Evacuate);
        return n;
    }

    function _dClose(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Default config: 10 HP per death, bonus 2500. hp 50.
        n = _addA(vs, n, "close: known, 3 creatures", _g(), _p(), 0, 0, Action.Close);

        // Known count: the exact field is used, creaturesHi ignored.
        Portal memory p = _p();
        p.creatures = 0;
        p.creaturesHi = 4;
        n = _addA(vs, n, "close: known zero creatures, creaturesHi ignored, empty", _g(), p, 0, 0, Action.Close);

        // Unknown count: creaturesHi is the worst case; the exact field is ignored, no base charge.
        p = _unsurveyed();
        p.creatures = 1;
        p.creaturesHi = 5;
        n = _addA(vs, n, "close: unknown count pays for creaturesHi, exact field ignored", _g(), p, 0, 0, Action.Close);
        p = _unsurveyed();
        p.creatures = 4;
        p.creaturesHi = 0;
        n = _addA(vs, n, "close: unknown count with creaturesHi 0 is empty", _g(), p, 0, 0, Action.Close);

        // Empty portal: nobody dies, nothing is lost; the slot still frees and pressure still rises.
        p = _p();
        p.creatures = 0;
        n = _addA(vs, n, "close: empty portal", _g(), p, 0, 0, Action.Close);

        // Crew inside.
        p = _p();
        p.creatures = 0;
        p.observerInside = true;
        n = _addA(vs, n, "close: observer only", _g(), p, 0, 0, Action.Close);
        p = _p();
        p.creatures = 0;
        p.rescuerInside = true;
        n = _addA(vs, n, "close: rescuer only", _g(), p, 0, 0, Action.Close);
        p = _p();
        p.observerInside = true;
        p.rescuerInside = true;
        n = _addA(vs, n, "close: both crew and 3 creatures (5 deaths = 50 HP)", _g(), p, 0, 0, Action.Close);
        Game memory g = _g();
        g.hp = 51;
        p = _p();
        p.observerInside = true;
        p.rescuerInside = true;
        n = _addA(vs, n, "close: hp 51 against loss 50 leaves 1", g, p, 0, 0, Action.Close);

        // hp floor.
        g = _g();
        g.hp = 5;
        n = _addA(vs, n, "close: hp below loss floors at zero", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.hp = 30;
        n = _addA(vs, n, "close: hp equal to loss floors at zero (strict test)", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.hp = 0;
        n = _addA(vs, n, "close: hp already zero", g, _p(), 0, 0, Action.Close);
        return n;
    }

    function _dCloseEdge(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Spawn pressure saturates at 1e9.
        Game memory g = _g();
        g.spawnDebt = 999_997_499;
        n = _addA(vs, n, "close: debt 1e9 - 1 after bonus", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.spawnDebt = 999_997_500;
        n = _addA(vs, n, "close: debt exactly 1e9 after bonus (no saturation)", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.spawnDebt = 999_997_501;
        n = _addA(vs, n, "close: debt saturates at 1e9", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.spawnDebt = uint32(MAX32);
        n = _addA(vs, n, "close: debt from uint32 max saturates", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.spawnDebt = 1000;
        n = _addA(vs, n, "close: bonus uint32 max saturates", g, _p(), 2, 0, Action.Close);
        n = _addA(vs, n, "close: zero bonus", _g(), _p(), 3, 0, Action.Close);

        // deaths is uint8 (truncates), the HP loss is uint256 then uint16 (truncates).
        Portal memory p = _unsurveyed();
        p.creaturesHi = 255;
        p.observerInside = true;
        p.rescuerInside = true;
        n = _addA(vs, n, "close: 257 deaths truncate to 1 in the outcome", _g(), p, 0, 0, Action.Close);
        p = _unsurveyed();
        p.creaturesHi = 255;
        p.observerInside = true;
        p.rescuerInside = true;
        n = _addA(vs, n, "close: loss 257000 caps at hp in hpLost (config 1)", _g(), p, 1, 0, Action.Close);
        p = _p();
        p.creatures = 2;
        n = _addA(vs, n, "close: loss 131070 caps at hp in hpLost (config 2)", _g(), p, 2, 0, Action.Close);
        n = _addA(vs, n, "close: deaths cost nothing (config 3)", _g(), _p(), 3, 0, Action.Close);

        // Closing is checked against openPortals.
        g = _g();
        g.openPortals = 0;
        n = _addA(vs, n, "close: openPortals underflows", g, _p(), 0, 0, Action.Close);
        g = _g();
        g.openPortals = 1;
        n = _addA(vs, n, "close: the last open portal", g, _p(), 0, 0, Action.Close);
        return n;
    }

    // ── directed: survey ─────────────────────────────────────────────────────

    /// @dev A deaf-style portal (all three ranges given by width). Centres of the
    /// ranges sit at the middle of 0..100 / 0..100 / 0..20.
    function _ranged(uint8 we, uint8 ws, uint8 wc) private pure returns (Portal memory p) {
        p = _unsurveyed();
        p.energyLo = 20;
        p.energyHi = 20 + we;
        p.stabilityLo = 30;
        p.stabilityHi = 30 + ws;
        p.creaturesLo = 0;
        p.creaturesHi = wc;
        p.energy = 77;
        p.stability = 66;
        p.creatures = 9;
    }

    /// @dev Mark the portal as already narrowed once (a Deaf portal after its first survey).
    function _flagged(Portal memory p) private pure returns (Portal memory) {
        p.narrowedOnce = true;
        return p;
    }

    function _directedSurvey(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Precise types read exact whatever the width.
        n = _addS(vs, n, "survey: precise type, wide ranges", _ranged(80, 70, 20), 0, 0, 12345);
        n = _addS(vs, n, "survey: precise type, wide ranges (resonant)", _ranged(80, 70, 20), 0, 3, 777);
        n = _addS(vs, n, "survey: precise type, point ranges", _ranged(0, 0, 0), 0, 1, 1);
        n = _addS(vs, n, "survey: precise type, word zero", _ranged(30, 30, 3), 0, 4, 0);
        n = _addS(vs, n, "survey: precise type, word uint256 max", _ranged(30, 30, 3), 0, 0, type(uint256).max);

        // Precise types ignore the flag.
        n = _addS(vs, n, "survey: precise type, flag set", _flagged(_ranged(80, 70, 20)), 0, 0, 12345);
        n = _addS(vs, n, "survey: precise type, flag set (resonant)", _flagged(_ranged(5, 5, 5)), 0, 3, 777);

        // Deaf (tp 2) first pass: narrows, sets the flag, whatever the widths.
        n = _addS(vs, n, "survey: deaf first pass, wide ranges", _ranged(60, 80, 20), 0, 2, 31337);
        n = _addS(vs, n, "survey: deaf first pass, narrow ranges", _ranged(3, 3, 3), 0, 2, 99);
        n = _addS(vs, n, "survey: deaf first pass, all widths 9", _ranged(9, 9, 9), 0, 2, 4242);
        n = _addS(vs, n, "survey: deaf first pass, all widths 10", _ranged(10, 10, 10), 0, 2, 4242);
        n = _addS(vs, n, "survey: deaf first pass, one wide among two narrow", _ranged(10, 11, 10), 0, 2, 7);
        n = _addS(vs, n, "survey: deaf first pass, point ranges", _ranged(0, 0, 0), 0, 2, 5);
        n = _addS(vs, n, "survey: deaf first pass, synthetic deaf type 5", _ranged(60, 80, 20), 0, 5, 8);

        // Deaf with the flag (narrowed by an earlier survey): reads exact.
        n = _addS(vs, n, "survey: deaf second pass, wide ranges", _flagged(_ranged(60, 80, 20)), 0, 2, 31337);
        n = _addS(vs, n, "survey: deaf second pass, narrow ranges", _flagged(_ranged(3, 3, 3)), 0, 2, 99);
        n = _addS(vs, n, "survey: deaf second pass, point ranges", _flagged(_ranged(0, 0, 0)), 0, 2, 5);
        n = _addS(vs, n, "survey: deaf second pass, word zero", _flagged(_ranged(30, 30, 3)), 0, 2, 0);
        n = _addS(vs, n, "survey: deaf second pass, word uint256 max", _flagged(_ranged(30, 30, 3)), 0, 2, type(uint256).max);
        n = _addS(vs, n, "survey: deaf second pass, synthetic deaf type 5", _flagged(_ranged(60, 80, 20)), 0, 5, 8);
        n = _addS(vs, n, "survey: deaf second pass, other config", _flagged(_ranged(40, 40, 10)), 3, 2, 3);

        // Narrowing at the edges: the new bounds clip to the old ones.
        Portal memory p = _ranged(20, 20, 12);
        n = _addS(vs, n, "survey: narrow, centre at the low end clips", p, 0, 2, _wordCentres(p, 20, 50, 0));
        p = _ranged(20, 20, 12);
        n = _addS(vs, n, "survey: narrow, centre at the high end clips", p, 0, 2, _wordCentres(p, 40, 30, 0));
        p = _ranged(20, 20, 12);
        n = _addS(vs, n, "survey: narrow, centre in the middle", p, 0, 2, _wordCentres(p, 30, 40, 0));
        // Widths 255 / 254 / 253 are the extreme spans that still fit uint8.
        p = _ranged(0, 0, 0);
        p.energyLo = 0;
        p.energyHi = 255;
        p.stabilityLo = 1;
        p.stabilityHi = 255;
        p.creaturesLo = 0;
        p.creaturesHi = 253;
        n = _addS(vs, n, "survey: narrow, widest uint8 ranges", p, 0, 2, 2024);
        p = _ranged(0, 0, 0);
        p.energyLo = 0;
        p.energyHi = 255;
        n = _addS(vs, n, "survey: deaf second pass, full-width energy range", _flagged(p), 0, 2, 2024);

        // Reverts: an inverted range panics on the narrow path (first pass) or on the
        // exact draw (precise type, or a Deaf portal with the flag).
        p = _ranged(3, 3, 3);
        p.energyLo = 30;
        p.energyHi = 20;
        n = _addS(vs, n, "survey: deaf first pass, inverted energy range (narrow panics)", p, 0, 2, 1);
        p = _ranged(3, 3, 3);
        p.creaturesLo = 4;
        p.creaturesHi = 2;
        n = _addS(vs, n, "survey: deaf first pass, inverted creatures range (narrow panics)", p, 0, 2, 1);
        p = _flagged(_ranged(3, 3, 3));
        p.stabilityLo = 50;
        p.stabilityHi = 40;
        n = _addS(vs, n, "survey: deaf second pass, inverted stability range (draw panics)", p, 0, 2, 1);
        p = _ranged(3, 3, 3);
        n = _addS(vs, n, "survey: precise type, inverted stability range (draw panics)", p, 0, 0, 1);
        p = _ranged(3, 3, 3);
        p.creaturesLo = 9;
        p.creaturesHi = 1;
        n = _addS(vs, n, "survey: precise type, inverted creatures range (draw panics)", p, 0, 3, 1);
        p = _ranged(3, 3, 3);
        p.energyLo = 21;
        p.energyHi = 20;
        n = _addS(vs, n, "survey: precise type, inverted energy range by one", p, 0, 1, 1);
        return n;
    }

    /// @dev Find a word whose salt-0 and salt-1 draws land the narrowing centres of
    /// the energy and stability ranges on `wantE` and `wantS` (any value for creatures).
    function _wordCentres(Portal memory p, uint8 wantE, uint8 wantS, uint8) private pure returns (uint256) {
        for (uint256 w = 1; w < 200000; w++) {
            if (
                RandomStub.inRange(EffectsLib._fromWord(w, 0), p.energyLo, p.energyHi) == wantE
                    && RandomStub.inRange(EffectsLib._fromWord(w, 1), p.stabilityLo, p.stabilityHi) == wantS
            ) return w;
        }
        revert("no word found for the requested centres");
    }

    // ── directed: blind rescuer reveal ───────────────────────────────────────

    function _blindPortal(uint8 lo, uint8 hi) private pure returns (Portal memory p) {
        p = _unsurveyed();
        p.creatures = 7; // stale; the reveal overwrites it
        p.creaturesLo = lo;
        p.creaturesHi = hi;
    }

    /// @dev A word whose creature draw (salt 3) over [lo, hi] is zero (`zero`) or not.
    function _wordBlind(uint8 lo, uint8 hi, bool zero) private pure returns (uint256) {
        for (uint256 w = 1; w < 100000; w++) {
            uint8 r = RandomStub.inRange(EffectsLib._fromWord(w, 3), lo, hi);
            if ((r == 0) == zero) return w;
        }
        revert("no word found for the requested outcome");
    }

    function _directedReveal(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Count rolls above zero: the rescuer walks in. rescuersFree is the caller's business.
        n = _addR(vs, n, "reveal: positive count", _g(), _blindPortal(0, 4), 0, _wordBlind(0, 4, false));
        n = _addR(vs, n, "reveal: positive count, range does not include zero", _g(), _blindPortal(1, 5), 0, 99);
        n = _addR(vs, n, "reveal: point range above zero", _g(), _blindPortal(5, 5), 0, 0);
        n = _addR(vs, n, "reveal: word uint256 max", _g(), _blindPortal(0, 255), 0, type(uint256).max);

        // Zero: the rescuer does not enter and occupies a cooldown cell (hoursElapsed 20 + 10).
        n = _addR(vs, n, "reveal: zero, first cell free", _g(), _blindPortal(0, 4), 0, _wordBlind(0, 4, true));
        n = _addR(vs, n, "reveal: zero, point range", _g(), _blindPortal(0, 0), 0, 1);

        Game memory g = _g();
        g.rescuerReadyAt0 = 31;
        n = _addR(vs, n, "reveal: zero, cell 0 busy so cell 1", g, _blindPortal(0, 4), 0, _wordBlind(0, 4, true));
        g = _g();
        g.rescuerReadyAt0 = 31;
        g.rescuerReadyAt1 = 32;
        g.rescuerReadyAt2 = 33;
        n = _addR(vs, n, "reveal: zero, only cell 3 free", g, _blindPortal(0, 4), 0, _wordBlind(0, 4, true));
        g = _g();
        g.rescuerReadyAt1 = 40;
        n = _addR(vs, n, "reveal: zero, cell 0 free beats later free cells", g, _blindPortal(0, 4), 0, _wordBlind(0, 4, true));

        // cooldown arithmetic: uint32(hoursElapsed + cooldown) truncates.
        g = _g();
        g.hoursElapsed = uint32(MAX32);
        n = _addR(vs, n, "reveal: zero, readyAt wraps uint32", g, _blindPortal(0, 0), 0, 1);
        g = _g();
        g.hoursElapsed = 0;
        n = _addR(vs, n, "reveal: zero, readyAt 0 (cooldown 0): cell stays 'free'", g, _blindPortal(0, 0), 2, 1);
        n = _addR(vs, n, "reveal: zero, cooldown 65535", _g(), _blindPortal(0, 0), 1, 1);
        n = _addR(vs, n, "reveal: zero, cooldown 3", _g(), _blindPortal(0, 0), 3, 1);

        // Reverts.
        g = _g();
        g.rescuerReadyAt0 = 31;
        g.rescuerReadyAt1 = 32;
        g.rescuerReadyAt2 = 33;
        g.rescuerReadyAt3 = 34;
        n = _addR(vs, n, "reveal: zero, every cooldown cell busy (NoFreeRescuerCell)", g, _blindPortal(0, 0), 0, 1);
        g = _g();
        g.rescuerReadyAt0 = 31;
        g.rescuerReadyAt1 = 32;
        g.rescuerReadyAt2 = 33;
        g.rescuerReadyAt3 = 34;
        n = _addR(vs, n, "reveal: positive count with every cell busy does not need a cell", g, _blindPortal(5, 5), 0, 1);
        n = _addR(vs, n, "reveal: inverted creatures range (draw panics)", _g(), _blindPortal(4, 1), 0, 1);
        n = _addR(vs, n, "reveal: inverted by one", _g(), _blindPortal(3, 2), 0, 7);
        return n;
    }

    // ── random vectors ───────────────────────────────────────────────────────

    function _r(uint256 i, string memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("portal-lab-effects-v1", i, tag)));
    }

    function _randomApply(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        for (uint256 i = 0; i < RANDOM_APPLY; i++) {
            Vec memory v = vs[n];
            v.label = "random";
            v.g = _randomGame(i);
            v.p = _randomPortal(i);
            v.cfg = uint8(_r(i, "cfg") % CONFIG_COUNT);
            v.tp = uint8(_r(i, "tp") % TP_COUNT);
            v.a = Action(_r(i, "action") % 9);
            n++;
        }
        return n;
    }

    function _randomSurvey(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        for (uint256 i = 0; i < RANDOM_SURVEY; i++) {
            Vec memory v = vs[n];
            v.label = "random";
            v.p = _randomPortal(1000 + i);
            v.cfg = uint8(_r(1000 + i, "cfg") % CONFIG_COUNT);
            v.tp = uint8(_r(1000 + i, "tp") % TP_COUNT);
            v.word = _r(1000 + i, "word");
            n++;
        }
        return n;
    }

    function _randomReveal(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        for (uint256 i = 0; i < RANDOM_REVEAL; i++) {
            Vec memory v = vs[n];
            v.label = "random";
            v.g = _randomGame(2000 + i);
            v.p = _randomPortal(2000 + i);
            v.cfg = uint8(_r(2000 + i, "cfg") % CONFIG_COUNT);
            v.word = _r(2000 + i, "word");
            n++;
        }
        return n;
    }

    function _randomGame(uint256 i) private pure returns (Game memory g) {
        uint256 x = _r(i, "game");
        g.startedAt = uint40(1000 + (x >> 8) % 100000);
        g.lastTickAt = uint40((x >> 24) % 200000);
        g.hoursElapsed = uint32((x >> 48) % 500);
        g.diedAtHour = uint32((x >> 64) % 500);
        g.hp = (x >> 80) % 12 == 0 ? uint16(101 + (x >> 84) % 40) : uint16((x >> 84) % 101);
        g.finished = (x >> 96) % 12 == 0;
        g.openPortals = (x >> 100) % 15 == 0 ? 0 : uint8(1 + (x >> 104) % 12);
        g.spawnDebt = (x >> 108) % 10 == 0 ? uint32(999_900_000 + (x >> 112) % 200_000_000) : uint32((x >> 112) % 100000);
        g.spawnCount = uint32((x >> 140) % 1000);
        g.rngNonce = uint32((x >> 160) % 1000);
        g.settled = (x >> 190) % 5 == 0;

        uint256 y = _r(i, "game2");
        g.power = uint16((y >> 8) % 101);
        g.observersFree = _crew(y >> 24);
        g.rescuersFree = _crew(y >> 40);
        g.rescuerReadyAt0 = (y >> 56) % 2 == 0 ? 0 : uint32(1 + (y >> 60) % 60);
        g.rescuerReadyAt1 = (y >> 72) % 2 == 0 ? 0 : uint32(1 + (y >> 76) % 60);
        g.rescuerReadyAt2 = (y >> 88) % 2 == 0 ? 0 : uint32(1 + (y >> 92) % 60);
        g.rescuerReadyAt3 = (y >> 104) % 2 == 0 ? 0 : uint32(1 + (y >> 108) % 60);
        g.creaturesRescued = (y >> 120) % 40 == 0 ? uint32(MAX32 - (y >> 124) % 5) : uint32((y >> 124) % 100);
    }

    /// @dev Free crew: mostly 1..3, sometimes 0 (underflow) or 255 (overflow).
    function _crew(uint256 x) private pure returns (uint8) {
        uint256 k = x % 24;
        if (k == 0) return 0;
        if (k == 1) return 255;
        return uint8(1 + (x >> 8) % 3);
    }

    function _randomPortal(uint256 i) private pure returns (Portal memory p) {
        uint256 x = _r(i, "portal");
        p.id = uint16((x >> 0) % 5000);
        p.portalType = PortalType((x >> 16) % 5);
        p.nameIndex = uint8((x >> 24) % 24);
        p.narrowedOnce = (x >> 200) % 3 == 0;
        p.status = ((x >> 40) & 0xff) < 21 ? PortalStatus.Empty : ((x >> 48) % 2 == 0 ? PortalStatus.Open : PortalStatus.Questioned);
        p.surveyed = (x >> 56) % 5 != 0;
        p.observerInside = (x >> 60) % 4 == 0;
        p.rescuerInside = (x >> 64) % 4 == 0;
        p.surveyPending = (x >> 68) % 5 == 0;
        p.rescuerPending = (x >> 72) % 6 == 0;
        p.creaturesKnown = p.surveyed ? (x >> 76) % 8 != 0 : (x >> 76) % 3 == 0;
        p.spawnedAtHour = uint32((x >> 80) % 500);
        p.snapshotAt = uint40((x >> 100) % 200000);

        uint256 y = _r(i, "portal2");
        p.stability = (y % 15 == 0) ? uint8(101 + (y >> 4) % 155) : uint8((y >> 8) % 101);
        p.energy = ((y >> 16) % 15 == 0) ? uint8(101 + (y >> 20) % 155) : uint8((y >> 24) % 101);
        p.creatures = (y >> 32) % 50 == 0 ? 255 : ((y >> 40) % 5 == 0 ? 0 : uint8((y >> 44) % 7));
        p.hoursToCollapse = uint16((y >> 56) % 61);

        // Ranges: mostly modest widths, sometimes inverted.
        uint256 z = _r(i, "portal3");
        (p.stabilityLo, p.stabilityHi) = _range(z, 101, 40);
        (p.energyLo, p.energyHi) = _range(z >> 16, 101, 40);
        (p.creaturesLo, p.creaturesHi) = _range(z >> 32, 6, 12);
    }

    /// @dev A random [lo, hi] inside [0, limit): width at most `maxWidth`, inverted 1 time in 30.
    function _range(uint256 x, uint256 limit, uint256 maxWidth) private pure returns (uint8 lo, uint8 hi) {
        uint256 l = x % limit;
        uint256 room = limit - 1 - l; // widest range that still ends inside [0, limit)
        uint256 w = (x >> 8) % ((room < maxWidth ? room : maxWidth) + 1);
        lo = uint8(l);
        hi = uint8(l + w);
        if ((x >> 16) % 30 == 0 && hi > lo) (lo, hi) = (hi, lo);
    }

    // ── evaluation through the harness ───────────────────────────────────────

    function _evalApply(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps, EffectsHarness h) private view {
        try h.applyAction(v.g, v.p, cfgs[v.cfg], tps[v.tp], v.a) returns (
            Game memory g2, Portal memory p2, EffectsLib.Outcome memory o
        ) {
            v.rg = g2;
            v.rp = p2;
            v.ro = o;
        } catch (bytes memory err) {
            v.reverted = true;
            v.err = VectorCodec.errorName(err);
        }
    }

    function _evalSurvey(Vec memory v, Config[] memory cfgs, PortalTypeParams[] memory tps, EffectsHarness h) private view {
        try h.survey(v.p, cfgs[v.cfg], tps[v.tp], v.word) returns (Portal memory p2, bool precise) {
            v.rp = p2;
            v.precise = precise;
        } catch (bytes memory err) {
            v.reverted = true;
            v.err = VectorCodec.errorName(err);
        }
    }

    function _evalReveal(Vec memory v, Config[] memory cfgs, EffectsHarness h) private view {
        try h.applyBlindRescuerReveal(v.g, v.p, cfgs[v.cfg], v.word) returns (
            Game memory g2, Portal memory p2, EffectsLib.Outcome memory o
        ) {
            v.rg = g2;
            v.rp = p2;
            v.ro = o;
        } catch (bytes memory err) {
            v.reverted = true;
            v.err = VectorCodec.errorName(err);
        }
    }

    // ── coverage ─────────────────────────────────────────────────────────────

    function _reg(Cov memory cv, string memory name) private pure {
        cv.names[cv.n] = name;
        cv.n++;
    }

    /// @dev Every branch the task (and the library) calls for. `_mark` with a name not
    /// in this list reverts, so a typo cannot silently create a tag that nobody requires.
    function _register() private pure returns (Cov memory cv) {
        cv.names = new string[](96);
        cv.counts = new uint256[](96);

        _reg(cv, "toggle: Open -> Questioned");
        _reg(cv, "toggle: Questioned -> Open");
        _reg(cv, "stabilize: plain");
        _reg(cv, "stabilize: clamps at the ceiling");
        _reg(cv, "stabilize: lands exactly on 100 (no clamp)");
        _reg(cv, "stabilize: energy floors at zero");
        _reg(cv, "stabilize: energy exactly 10 lands on zero");
        _reg(cv, "stabilize: stability above 100 to begin with");
        _reg(cv, "stabilize/destabilize: step truncated by the division");
        _reg(cv, "destabilize: plain");
        _reg(cv, "destabilize: stability floors at zero");
        _reg(cv, "destabilize: stability exactly equal to the step");
        _reg(cv, "destabilize: energy clamps at 100");
        _reg(cv, "destabilize: energy lands exactly on 100");
        _reg(cv, "send observer (surveyed portal)");
        _reg(cv, "recall observer");
        _reg(cv, "send rescuer (sighted)");
        _reg(cv, "recall rescuer");
        _reg(cv, "evacuate: surveyed, everyone out");
        _reg(cv, "evacuate: blind, one stays");
        _reg(cv, "evacuate: blind, last creature saves nobody");
        _reg(cv, "evacuate: zero creatures");
        _reg(cv, "evacuate: heal clamped at hpMax");
        _reg(cv, "evacuate: heal lands exactly on hpMax");
        _reg(cv, "evacuate: heal below hpMax");
        _reg(cv, "evacuate: hp already at hpMax");
        _reg(cv, "close: known creature count");
        _reg(cv, "close: unknown count pays creaturesHi");
        _reg(cv, "close: unknown count ignores the exact field");
        _reg(cv, "close: known count ignores creaturesHi");
        _reg(cv, "close: empty portal");
        _reg(cv, "close: observer inside");
        _reg(cv, "close: rescuer inside");
        _reg(cv, "close: both crew inside");
        _reg(cv, "close: hp floors at zero");
        _reg(cv, "close: hp equal to loss");
        _reg(cv, "close: spawn debt saturates");
        _reg(cv, "close: spawn debt lands exactly on the cap");
        _reg(cv, "close: deaths truncate in the outcome");
        _reg(cv, "close: hpLost capped at the hp before the hit");
        _reg(cv, "close: hpLost is the full loss when hp covers it");
        _reg(cv, "revert: send observer with none free");
        _reg(cv, "revert: recall observer at 255");
        _reg(cv, "revert: send rescuer with none free");
        _reg(cv, "revert: recall rescuer at 255");
        _reg(cv, "revert: evacuate with rescuersFree at 255");
        _reg(cv, "revert: evacuate with hp above hpMax");
        _reg(cv, "revert: evacuate overflows creaturesRescued");
        _reg(cv, "revert: close with openPortals at zero");
        _reg(cv, "survey: precise type");
        _reg(cv, "survey: precise type, flag irrelevant");
        _reg(cv, "survey: deaf first pass narrows and sets the flag");
        _reg(cv, "survey: deaf with the flag reads exact");
        _reg(cv, "survey: deaf with the flag, wide ranges, reads exact");
        _reg(cv, "survey: narrowing clips the low bound");
        _reg(cv, "survey: narrowing clips the high bound");
        _reg(cv, "survey: narrowing keeps both bounds inside");
        _reg(cv, "survey revert: inverted range on the narrow path");
        _reg(cv, "survey revert: inverted range on the exact draw");
        _reg(cv, "reveal: positive count, rescuer walks in");
        _reg(cv, "reveal: zero count, cell 0");
        _reg(cv, "reveal: zero count, a later cell");
        _reg(cv, "reveal: zero count, readyAt wraps uint32");
        _reg(cv, "reveal: zero count, readyAt is zero");
        _reg(cv, "reveal revert: no free cooldown cell");
        _reg(cv, "reveal revert: inverted creatures range");
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
        revert(string.concat("unregistered coverage tag: ", name));
    }

    function _requireCoverage(Cov memory cv) private pure {
        for (uint256 i = 0; i < cv.n; i++) {
            require(cv.counts[i] > 0, string.concat("branch not covered by any vector: ", cv.names[i]));
        }
    }

    function _isPanic(Vec memory v) private pure returns (bool) {
        return v.reverted && keccak256(bytes(v.err)) == keccak256(bytes("Panic(0x11)"));
    }

    function _tagApply(Cov memory cv, Vec memory v, Config memory c, PortalTypeParams memory t) private pure {
        Action a = v.a;
        Game memory g = v.g;
        Portal memory p = v.p;

        if (v.reverted) {
            bool panic = _isPanic(v);
            _mark(cv, panic && a == Action.SendObserver && g.observersFree == 0, "revert: send observer with none free");
            _mark(cv, panic && a == Action.RecallObserver && g.observersFree == 255, "revert: recall observer at 255");
            _mark(cv, panic && a == Action.SendRescuer && g.rescuersFree == 0, "revert: send rescuer with none free");
            _mark(cv, panic && a == Action.RecallRescuer && g.rescuersFree == 255, "revert: recall rescuer at 255");
            _mark(cv, panic && a == Action.Evacuate && g.rescuersFree == 255, "revert: evacuate with rescuersFree at 255");
            _mark(
                cv,
                panic && a == Action.Evacuate && g.rescuersFree < 255 && g.hp > c.hpMax
                    && uint256(g.creaturesRescued) + p.creatures <= MAX32,
                "revert: evacuate with hp above hpMax"
            );
            _mark(
                cv,
                panic && a == Action.Evacuate && g.rescuersFree < 255 && g.hp <= c.hpMax && p.creatures > 0
                    && uint256(g.creaturesRescued) + (p.surveyed ? p.creatures : p.creatures - 1) > MAX32,
                "revert: evacuate overflows creaturesRescued"
            );
            _mark(cv, panic && a == Action.Close && g.openPortals == 0, "revert: close with openPortals at zero");
            return;
        }

        uint256 step = (25 * uint256(t.actionMultiplierPct)) / 100;

        _mark(cv, a == Action.ToggleQuestioned && p.status == PortalStatus.Open && v.rp.status == PortalStatus.Questioned, "toggle: Open -> Questioned");
        _mark(cv, a == Action.ToggleQuestioned && p.status == PortalStatus.Questioned && v.rp.status == PortalStatus.Open, "toggle: Questioned -> Open");

        _mark(cv, a == Action.Stabilize && uint256(p.stability) + step < 100, "stabilize: plain");
        _mark(cv, a == Action.Stabilize && uint256(p.stability) + step > 100 && v.rp.stability == 100, "stabilize: clamps at the ceiling");
        _mark(cv, a == Action.Stabilize && uint256(p.stability) + step == 100 && v.rp.stability == 100, "stabilize: lands exactly on 100 (no clamp)");
        _mark(cv, a == Action.Stabilize && p.energy < 10 && v.rp.energy == 0, "stabilize: energy floors at zero");
        _mark(cv, a == Action.Stabilize && p.energy == 10 && v.rp.energy == 0, "stabilize: energy exactly 10 lands on zero");
        _mark(cv, a == Action.Stabilize && p.stability > 100 && v.rp.stability == 100, "stabilize: stability above 100 to begin with");
        _mark(cv, (a == Action.Stabilize || a == Action.Destabilize) && (25 * uint256(t.actionMultiplierPct)) % 100 != 0, "stabilize/destabilize: step truncated by the division");

        _mark(cv, a == Action.Destabilize && uint256(p.stability) > step && uint256(p.energy) + 10 <= 100, "destabilize: plain");
        _mark(cv, a == Action.Destabilize && uint256(p.stability) <= step && v.rp.stability == 0, "destabilize: stability floors at zero");
        _mark(cv, a == Action.Destabilize && uint256(p.stability) == step && v.rp.stability == 0, "destabilize: stability exactly equal to the step");
        _mark(cv, a == Action.Destabilize && uint256(p.energy) + 10 > 100 && v.rp.energy == 100, "destabilize: energy clamps at 100");
        _mark(cv, a == Action.Destabilize && uint256(p.energy) + 10 == 100 && v.rp.energy == 100, "destabilize: energy lands exactly on 100");

        _mark(cv, a == Action.SendObserver && v.rp.observerInside && v.rg.observersFree + 1 == g.observersFree, "send observer (surveyed portal)");
        _mark(cv, a == Action.RecallObserver && !v.rp.observerInside && v.rg.observersFree == g.observersFree + 1, "recall observer");
        _mark(cv, a == Action.SendRescuer && v.rp.rescuerInside && v.rg.rescuersFree + 1 == g.rescuersFree, "send rescuer (sighted)");
        _mark(cv, a == Action.RecallRescuer && !v.rp.rescuerInside && v.rg.rescuersFree == g.rescuersFree + 1, "recall rescuer");

        if (a == Action.Evacuate) _tagEvacuate(cv, v, c);
        if (a == Action.Close) _tagClose(cv, v, c);
    }

    function _tagEvacuate(Cov memory cv, Vec memory v, Config memory c) private pure {
        Game memory g = v.g;
        Portal memory p = v.p;
        uint256 saved = v.ro.rescued;
        uint256 healed = uint256(c.healPerCreature) * saved;

        _mark(cv, p.surveyed && p.creatures > 0 && saved == p.creatures && v.ro.leftBehind == 0, "evacuate: surveyed, everyone out");
        _mark(cv, !p.surveyed && p.creatures >= 2 && saved == p.creatures - 1 && v.ro.leftBehind == 1, "evacuate: blind, one stays");
        _mark(cv, !p.surveyed && p.creatures == 1 && saved == 0 && v.ro.leftBehind == 1, "evacuate: blind, last creature saves nobody");
        _mark(cv, p.creatures == 0 && saved == 0, "evacuate: zero creatures");
        _mark(cv, saved > 0 && uint256(g.hp) + healed > c.hpMax && v.rg.hp == c.hpMax, "evacuate: heal clamped at hpMax");
        _mark(cv, saved > 0 && healed > 0 && uint256(g.hp) + healed == c.hpMax, "evacuate: heal lands exactly on hpMax");
        _mark(cv, saved > 0 && healed > 0 && uint256(g.hp) + healed < c.hpMax && v.ro.hpGained == healed, "evacuate: heal below hpMax");
        _mark(cv, saved > 0 && g.hp == c.hpMax && v.ro.hpGained == 0, "evacuate: hp already at hpMax");
    }

    function _tagClose(Cov memory cv, Vec memory v, Config memory c) private pure {
        Game memory g = v.g;
        Portal memory p = v.p;
        uint256 crew = (p.observerInside ? 1 : 0) + (p.rescuerInside ? 1 : 0);
        uint256 deathsFull = (p.creaturesKnown ? uint256(p.creatures) : uint256(p.creaturesHi)) + crew;
        uint256 loss = uint256(c.hpCollapsePerDeath) * deathsFull;

        _mark(cv, p.creaturesKnown && p.creatures > 0 && deathsFull > 0, "close: known creature count");
        _mark(cv, !p.creaturesKnown && p.creaturesHi > 0 && deathsFull == p.creaturesHi + crew, "close: unknown count pays creaturesHi");
        _mark(cv, !p.creaturesKnown && p.creatures != p.creaturesHi, "close: unknown count ignores the exact field");
        _mark(cv, p.creaturesKnown && p.creaturesHi != p.creatures, "close: known count ignores creaturesHi");
        _mark(cv, deathsFull == 0 && v.ro.deaths == 0 && v.ro.hpLost == 0 && v.rg.hp == g.hp, "close: empty portal");
        _mark(cv, p.observerInside && !p.rescuerInside, "close: observer inside");
        _mark(cv, p.rescuerInside && !p.observerInside, "close: rescuer inside");
        _mark(cv, p.rescuerInside && p.observerInside, "close: both crew inside");
        _mark(cv, loss > 0 && g.hp < loss && v.rg.hp == 0, "close: hp floors at zero");
        _mark(cv, loss > 0 && g.hp == loss && v.rg.hp == 0, "close: hp equal to loss");
        _mark(
            cv,
            uint256(g.spawnDebt) + c.closePressureBonus > 1_000_000_000 && v.rg.spawnDebt == 1_000_000_000,
            "close: spawn debt saturates"
        );
        _mark(
            cv,
            uint256(g.spawnDebt) + c.closePressureBonus == 1_000_000_000 && v.rg.spawnDebt == 1_000_000_000,
            "close: spawn debt lands exactly on the cap"
        );
        _mark(cv, deathsFull > 255 && v.ro.deaths == deathsFull % 256, "close: deaths truncate in the outcome");
        _mark(cv, loss > 0 && g.hp < loss && v.ro.hpLost == g.hp, "close: hpLost capped at the hp before the hit");
        _mark(cv, loss > 0 && g.hp >= loss && v.ro.hpLost == loss, "close: hpLost is the full loss when hp covers it");
    }

    function _tagSurvey(Cov memory cv, Vec memory v, Config memory, PortalTypeParams memory t) private pure {
        Portal memory p = v.p;

        if (v.reverted) {
            bool inverted = p.energyHi < p.energyLo || p.stabilityHi < p.stabilityLo || p.creaturesHi < p.creaturesLo;
            bool onDraw = t.surveyPrecise || p.narrowedOnce;
            _mark(cv, _isPanic(v) && inverted && onDraw, "survey revert: inverted range on the exact draw");
            _mark(cv, _isPanic(v) && inverted && !onDraw, "survey revert: inverted range on the narrow path");
            return;
        }

        uint256 widest = _widest(p);

        _mark(cv, t.surveyPrecise && v.precise && v.rp.surveyed, "survey: precise type");
        _mark(cv, t.surveyPrecise && v.precise && p.narrowedOnce, "survey: precise type, flag irrelevant");
        _mark(
            cv,
            !t.surveyPrecise && !p.narrowedOnce && !v.precise && v.rp.narrowedOnce && !v.rp.surveyed,
            "survey: deaf first pass narrows and sets the flag"
        );
        _mark(cv, !t.surveyPrecise && p.narrowedOnce && v.precise && v.rp.surveyed, "survey: deaf with the flag reads exact");
        _mark(
            cv,
            !t.surveyPrecise && p.narrowedOnce && v.precise && v.rp.surveyed && widest > 10,
            "survey: deaf with the flag, wide ranges, reads exact"
        );
        _mark(cv, !v.precise && (v.rp.energyLo == p.energyLo || v.rp.stabilityLo == p.stabilityLo || v.rp.creaturesLo == p.creaturesLo), "survey: narrowing clips the low bound");
        _mark(cv, !v.precise && (v.rp.energyHi == p.energyHi || v.rp.stabilityHi == p.stabilityHi || v.rp.creaturesHi == p.creaturesHi), "survey: narrowing clips the high bound");
        _mark(
            cv,
            !v.precise && v.rp.energyLo > p.energyLo && v.rp.energyHi < p.energyHi,
            "survey: narrowing keeps both bounds inside"
        );
    }

    function _widest(Portal memory p) private pure returns (uint256) {
        uint256 we = uint256(p.energyHi) - p.energyLo;
        uint256 ws = uint256(p.stabilityHi) - p.stabilityLo;
        uint256 wc = uint256(p.creaturesHi) - p.creaturesLo;
        return we > ws ? (we > wc ? we : wc) : (ws > wc ? ws : wc);
    }

    function _tagReveal(Cov memory cv, Vec memory v, Config memory c) private pure {
        Game memory g = v.g;
        Portal memory p = v.p;

        if (v.reverted) {
            bool noCell = keccak256(bytes(v.err)) == keccak256(bytes("NoFreeRescuerCell"));
            _mark(cv, noCell, "reveal revert: no free cooldown cell");
            _mark(cv, _isPanic(v) && p.creaturesHi < p.creaturesLo, "reveal revert: inverted creatures range");
            return;
        }

        _mark(cv, v.rp.rescuerInside && v.rp.creatures > 0 && !v.ro.rescuerBlindMiss, "reveal: positive count, rescuer walks in");
        bool zero = v.ro.rescuerBlindMiss;
        uint256 readyAt = uint256(g.hoursElapsed) + c.rescuerCooldownHours;
        _mark(cv, zero && g.rescuerReadyAt0 == 0 && v.rg.rescuerReadyAt0 == v.ro.rescuerReadyAtHour, "reveal: zero count, cell 0");
        _mark(cv, zero && g.rescuerReadyAt0 != 0, "reveal: zero count, a later cell");
        _mark(cv, zero && readyAt > MAX32 && v.ro.rescuerReadyAtHour == readyAt % (MAX32 + 1), "reveal: zero count, readyAt wraps uint32");
        _mark(cv, zero && v.ro.rescuerReadyAtHour == 0, "reveal: zero count, readyAt is zero");
    }

    // ── output ───────────────────────────────────────────────────────────────

    function _head(Config[] memory cfgs, PortalTypeParams[] memory tps) private pure returns (string memory) {
        string memory s = '{"configs":[';
        for (uint256 i = 0; i < cfgs.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.configJson(cfgs[i]));
        }
        s = string.concat(s, '],"typeParams":[');
        for (uint256 i = 0; i < tps.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.typeParamsJson(tps[i]));
        }
        return string.concat(s, '],"applyAction":[');
    }

    function _writeGroup(Vec[] memory vs, uint256 n, uint8 kind) private {
        for (uint256 i = 0; i < n; i++) {
            // Each line builds dozens of throw-away strings and EVM memory is never
            // freed; rewinding the free-memory pointer after the write keeps a
            // 1000+ vector run under Foundry's memory cap. Nothing built inside the
            // iteration is used after it.
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(PATH, _line(vs[i], kind, i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    function _line(Vec memory v, uint8 kind, bool last) private pure returns (string memory) {
        string memory head = string.concat('{"label":"', v.label, '",');
        string memory exp = string.concat(
            '"expected":{', VectorCodec.kb("reverted", v.reverted), ',"error":"', v.err, '",'
        );
        string memory body;
        if (kind == 0) {
            body = string.concat(
                '"game":', VectorCodec.gameJson(v.g), ',"portal":', VectorCodec.portalJson(v.p), ",",
                VectorCodec.kv("config", v.cfg), ",", VectorCodec.kv("tp", v.tp), ",", VectorCodec.kv("action", uint8(v.a)), ",",
                exp,
                '"game":', VectorCodec.gameJson(v.rg), ',"portal":', VectorCodec.portalJson(v.rp),
                ',"outcome":', VectorCodec.outcomeJson(v.ro), "}}"
            );
        } else if (kind == 1) {
            body = string.concat(
                '"portal":', VectorCodec.portalJson(v.p), ",",
                VectorCodec.kv("config", v.cfg), ",", VectorCodec.kv("tp", v.tp), ",", VectorCodec.ks("word", v.word), ",",
                exp,
                '"portal":', VectorCodec.portalJson(v.rp), ",", VectorCodec.kb("precise", v.precise), "}}"
            );
        } else {
            body = string.concat(
                '"game":', VectorCodec.gameJson(v.g), ',"portal":', VectorCodec.portalJson(v.p), ",",
                VectorCodec.kv("config", v.cfg), ",", VectorCodec.ks("word", v.word), ",",
                exp,
                '"game":', VectorCodec.gameJson(v.rg), ',"portal":', VectorCodec.portalJson(v.rp),
                ',"outcome":', VectorCodec.outcomeJson(v.ro), "}}"
            );
        }
        return string.concat(head, body, last ? "" : ",");
    }
}
