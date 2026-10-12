// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RulesLib} from "../src/RulesLib.sol";
import {RiskLib} from "../src/RiskLib.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {
    Game,
    Portal,
    Config,
    PortalType,
    PortalStatus,
    RiskLevel,
    Action,
    Refusal
} from "../src/PortalLabTypes.sol";
import {VectorCodec} from "../test/utils/VectorCodec.sol";

/// @notice Generates the golden vectors for the RulesLib TS mirror:
///   ../shared/test/vectors/rules-vectors.json  — (game, portal, config, slot, action) → (refusal, cost)
///   ../shared/test/vectors/enums.json          — member → integer value of every enum
/// Run from contracts/:  forge script script/GenRulesVectors.s.sol
/// No RPC, no broadcast. The file format is documented in
/// shared/test/support/vectorFormat.ts.
///
/// The set is RANDOM_COUNT pseudo-random vectors (deterministic: keccak of a tag and
/// the index) PLUS directed vectors. Random alone would almost never reach the rare
/// refusals (SurveyPending, the 84/85 risk gate, exact power boundaries), so the
/// directed block builds each one on purpose. `run` aborts if any `Refusal`/`Action`
/// that `RulesLib.check` can produce is missing from the final set.
///
/// `Refusal.RandomnessTimeout` is the one code that cannot appear: it is not a rule
/// refusal and `RulesLib.check` never returns it (see its NatSpec in PortalLabTypes).
contract GenRulesVectors is Script {
    uint256 private constant RANDOM_COUNT = 1000;
    uint256 private constant CAPACITY = 2000;
    uint256 private constant CONFIG_COUNT = 4;
    string private constant DIR = "../shared/test/vectors/";

    struct Vec {
        string label;
        Game g;
        Portal p;
        uint8 cfg;
        uint8 slot;
        Action a;
    }

    function run() external {
        Config[] memory cfgs = _configs();
        Vec[] memory vs = new Vec[](CAPACITY);
        uint256 n = 0;

        n = _directed(vs, n);
        uint256 directedCount = n;
        n = _random(vs, n);

        _requireCoverage(vs, n, cfgs);

        string memory path = string.concat(DIR, "rules-vectors.json");
        vm.writeFile(path, _head(cfgs));
        for (uint256 i = 0; i < n; i++) {
            // Each line builds dozens of throw-away strings and EVM memory is never
            // freed; rewinding the free-memory pointer after the write keeps a
            // 1000+ vector run under Foundry's memory cap. Nothing built inside the
            // iteration is used after it.
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            vm.writeLine(path, _vectorLine(vs[i], cfgs, i + 1 == n));
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
        vm.writeLine(string.concat(DIR, "rules-vectors.json"), "]}");

        vm.writeFile(string.concat(DIR, "enums.json"), _enumsJson());

        console.log("rules vectors written:", n);
        console.log("  directed:", directedCount);
        console.log("  random:", n - directedCount);
    }

    // ── configs ──────────────────────────────────────────────────────────────

    /// @dev Four configs, each built fresh (memory structs are references).
    ///   0 — the deployed GameConfig;
    ///   1 — Toggle costs power, Close thresholds at zero (almost nothing may close);
    ///   2 — costs doubled, wide Close thresholds (hours ≤ 48, stability < 100);
    ///   3 — every action free, so power never binds.
    function _configs() private pure returns (Config[] memory cfgs) {
        cfgs = new Config[](CONFIG_COUNT);
        cfgs[0] = GameConfig.config();

        Config memory c1 = GameConfig.config();
        c1.costToggleQuestioned = 3;
        c1.closeHoursAtMost = 0;
        c1.closeStabilityBelow = 0;
        cfgs[1] = c1;

        Config memory c2 = GameConfig.config();
        c2.costToggleQuestioned = 1;
        c2.costStabilize = 10;
        c2.costDestabilize = 10;
        c2.costSendObserver = 20;
        c2.costRecallObserver = 10;
        c2.costSendRescuer = 40;
        c2.costRecallRescuer = 20;
        c2.costEvacuate = 20;
        c2.costClose = 50;
        c2.closeHoursAtMost = 48;
        c2.closeStabilityBelow = 100;
        cfgs[2] = c2;

        Config memory c3 = GameConfig.config();
        c3.costToggleQuestioned = 0;
        c3.costStabilize = 0;
        c3.costDestabilize = 0;
        c3.costSendObserver = 0;
        c3.costRecallObserver = 0;
        c3.costSendRescuer = 0;
        c3.costRecallRescuer = 0;
        c3.costEvacuate = 0;
        c3.costClose = 0;
        cfgs[3] = c3;
    }

    // ── fresh base states (never share a struct between two vectors) ─────────

    function _g() private pure returns (Game memory g) {
        g.startedAt = 1000;
        g.lastTickAt = 1000;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
    }

    /// @dev Open, surveyed, exact numbers, ranges bracketing them, nobody inside,
    /// Medium risk (≈50): clear of every gate.
    function _p() private pure returns (Portal memory p) {
        p.id = 1;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.stability = 50;
        p.energy = 50;
        p.creatures = 2;
        p.hoursToCollapse = 24;
        p.stabilityLo = 40;
        p.stabilityHi = 60;
        p.energyLo = 40;
        p.energyHi = 60;
        p.creaturesLo = 1;
        p.creaturesHi = 3;
    }

    function _add(Vec[] memory vs, uint256 n, string memory label, Game memory g, Portal memory p, uint8 cfg, uint8 slot, Action a)
        private
        pure
        returns (uint256)
    {
        Vec memory v = vs[n];
        v.label = label;
        v.g = g;
        v.p = p;
        v.cfg = cfg;
        v.slot = slot;
        v.a = a;
        return n + 1;
    }

    // ── directed vectors ─────────────────────────────────────────────────────

    function _directed(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Config[] memory cfgs = _configs();
        for (uint8 ai = 0; ai < 9; ai++) {
            Action a = Action(ai);
            n = _directedForEveryAction(vs, n, cfgs, a);
        }
        n = _directedStabilize(vs, n);
        n = _directedObserver(vs, n);
        n = _directedRescuer(vs, n);
        n = _directedEvacuate(vs, n);
        n = _directedClose(vs, n);
        n = _directedRiskGates(vs, n);
        return n;
    }

    /// @dev Cases that apply to all nine actions: the gates before the action table
    /// (1–3) and the power rule (6). For actions needing special state the base
    /// portal may legitimately refuse for another reason — that is still a valid
    /// vector (it pins the order); the action-specific blocks cover the positives.
    function _directedForEveryAction(Vec[] memory vs, uint256 n, Config[] memory cfgs, Action a)
        private
        pure
        returns (uint256)
    {
        n = _add(vs, n, "base", _g(), _ready(a), 0, 0, a);

        Portal memory q = _ready(a);
        q.status = PortalStatus.Questioned;
        n = _add(vs, n, "base questioned", _g(), q, 0, 0, a);

        Game memory g = _g();
        g.startedAt = 0;
        n = _add(vs, n, "never started", g, _ready(a), 0, 0, a);

        g = _g();
        g.finished = true;
        n = _add(vs, n, "finished", g, _ready(a), 0, 0, a);

        g = _g();
        g.startedAt = 0;
        Portal memory e = _ready(a);
        e.status = PortalStatus.Empty;
        n = _add(vs, n, "inactive beats invalid slot and empty", g, e, 0, 12, a);

        e = _ready(a);
        e.status = PortalStatus.Empty;
        n = _add(vs, n, "invalid slot beats empty", _g(), e, 0, 12, a);

        n = _add(vs, n, "invalid slot 12", _g(), _ready(a), 0, 12, a);
        n = _add(vs, n, "invalid slot 255", _g(), _ready(a), 0, 255, a);
        n = _add(vs, n, "last valid slot 11", _g(), _ready(a), 0, 11, a);

        e = _ready(a);
        e.status = PortalStatus.Empty;
        n = _add(vs, n, "empty", _g(), e, 0, 0, a);

        // Power boundary on each config: cost-1 refuses, cost allows.
        for (uint8 ci = 0; ci < CONFIG_COUNT; ci++) {
            uint16 cst = RulesLib.cost(cfgs[ci], a);
            if (cst > 0) {
                g = _g();
                g.power = cst - 1;
                n = _add(vs, n, "power one short", g, _ready(a), ci, 0, a);
            }
            g = _g();
            g.power = cst;
            n = _add(vs, n, "power exactly cost", g, _ready(a), ci, 0, a);
        }
        g = _g();
        g.power = 0;
        n = _add(vs, n, "power zero", g, _ready(a), 0, 0, a);
        return n;
    }

    /// @dev A portal in which `a`'s own preconditions hold, so the generic cases
    /// above isolate the rule they are probing.
    function _ready(Action a) private pure returns (Portal memory p) {
        p = _p();
        if (a == Action.RecallObserver) p.observerInside = true;
        if (a == Action.RecallRescuer || a == Action.Evacuate) p.rescuerInside = true;
        if (a == Action.Close) p.hoursToCollapse = 3;
    }

    function _directedStabilize(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        for (uint8 ai = 1; ai <= 2; ai++) {
            Action a = Action(ai);
            Portal memory p = _p();
            p.surveyed = false;
            n = _add(vs, n, "unsurveyed", _g(), p, 0, 0, a);

            p = _p();
            p.surveyed = false;
            Game memory g = _g();
            g.power = 0;
            n = _add(vs, n, "not surveyed beats no power", g, p, 0, 0, a);
        }
        return n;
    }

    function _directedObserver(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Portal memory p = _p();
        p.observerInside = true;
        n = _add(vs, n, "observer already inside", _g(), p, 0, 0, Action.SendObserver);

        p = _p();
        p.observerInside = true;
        Game memory g = _g();
        g.observersFree = 0;
        g.power = 0;
        n = _add(vs, n, "already inside beats no crew and no power", g, p, 0, 0, Action.SendObserver);

        // Surveyed, Critical: stability 0, energy 100, 1 h left.
        p = _p();
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 1;
        n = _add(vs, n, "surveyed critical", _g(), p, 0, 0, Action.SendObserver);

        p = _p();
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 1;
        g = _g();
        g.observersFree = 0;
        n = _add(vs, n, "risk too high beats no crew", g, p, 0, 0, Action.SendObserver);

        // ANTI-DEADLOCK: an unsurveyed portal with a lethal worst corner must still
        // admit an observer (observing IS surveying).
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.stabilityLo = 0;
        p.energyHi = 100;
        p.creaturesHi = 9;
        p.hoursToCollapse = 1;
        n = _add(vs, n, "unsurveyed worst corner critical: observer still allowed", _g(), p, 0, 0, Action.SendObserver);

        g = _g();
        g.observersFree = 0;
        n = _add(vs, n, "no observer free", g, _p(), 0, 0, Action.SendObserver);

        g = _g();
        g.observersFree = 0;
        g.power = 0;
        n = _add(vs, n, "no crew beats no power", g, _p(), 0, 0, Action.SendObserver);

        // RecallObserver.
        n = _add(vs, n, "recall: nobody inside", _g(), _p(), 0, 0, Action.RecallObserver);

        p = _p();
        p.observerInside = true;
        p.surveyPending = true;
        n = _add(vs, n, "recall: survey pending", _g(), p, 0, 0, Action.RecallObserver);

        p = _p();
        p.surveyPending = true;
        n = _add(vs, n, "recall: nobody inside beats survey pending", _g(), p, 0, 0, Action.RecallObserver);

        p = _p();
        p.observerInside = true;
        n = _add(vs, n, "recall: ok", _g(), p, 0, 0, Action.RecallObserver);
        return n;
    }

    function _directedRescuer(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        Portal memory p = _p();
        p.rescuerInside = true;
        n = _add(vs, n, "rescuer already inside", _g(), p, 0, 0, Action.SendRescuer);

        p = _p();
        p.rescuerInside = true;
        p.creatures = 0;
        n = _add(vs, n, "already inside beats no creatures", _g(), p, 0, 0, Action.SendRescuer);

        p = _p();
        p.creatures = 0;
        n = _add(vs, n, "creatures known zero", _g(), p, 0, 0, Action.SendRescuer);

        p = _p();
        p.creatures = 0;
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 1;
        n = _add(vs, n, "no creatures beats risk", _g(), p, 0, 0, Action.SendRescuer);

        // Blind: unsurveyed, count unknown, benign worst corner → allowed.
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creatures = 0;
        n = _add(vs, n, "blind, benign worst corner: allowed", _g(), p, 0, 0, Action.SendRescuer);

        // Blind with a lethal worst corner → cautious gate.
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creatures = 0;
        p.stabilityLo = 0;
        p.energyHi = 100;
        p.creaturesHi = 5;
        n = _add(vs, n, "blind, critical worst corner", _g(), p, 0, 0, Action.SendRescuer);

        // Blind with count known zero is a NoCreatures, not a gamble.
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = true;
        p.creatures = 0;
        n = _add(vs, n, "unsurveyed but count known zero", _g(), p, 0, 0, Action.SendRescuer);

        // Surveyed critical.
        p = _p();
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 1;
        n = _add(vs, n, "surveyed critical", _g(), p, 0, 0, Action.SendRescuer);

        // Observer inside raises lives by one in both risk paths.
        p = _p();
        p.observerInside = true;
        n = _add(vs, n, "observer inside, ok", _g(), p, 0, 0, Action.SendRescuer);

        Game memory g = _g();
        g.rescuersFree = 0;
        n = _add(vs, n, "no rescuer free", g, _p(), 0, 0, Action.SendRescuer);

        g = _g();
        g.rescuersFree = 0;
        g.power = 0;
        n = _add(vs, n, "no crew beats no power", g, _p(), 0, 0, Action.SendRescuer);

        g = _g();
        g.rescuersFree = 0;
        p = _p();
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 1;
        n = _add(vs, n, "risk too high beats no crew", g, p, 0, 0, Action.SendRescuer);

        // RecallRescuer.
        n = _add(vs, n, "recall: nobody inside", _g(), _p(), 0, 0, Action.RecallRescuer);
        p = _p();
        p.rescuerInside = true;
        n = _add(vs, n, "recall: ok", _g(), p, 0, 0, Action.RecallRescuer);
        return n;
    }

    function _directedEvacuate(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        n = _add(vs, n, "no rescuer inside", _g(), _p(), 0, 0, Action.Evacuate);

        Portal memory p = _p();
        p.creatures = 0;
        n = _add(vs, n, "no creatures beats no rescuer", _g(), p, 0, 0, Action.Evacuate);

        p = _p();
        p.creatures = 0;
        p.rescuerInside = true;
        n = _add(vs, n, "no creatures, rescuer inside", _g(), p, 0, 0, Action.Evacuate);

        // Blind evacuation: unsurveyed, count unknown, rescuer inside → allowed.
        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creatures = 0;
        p.rescuerInside = true;
        n = _add(vs, n, "blind evacuate: allowed", _g(), p, 0, 0, Action.Evacuate);

        p = _p();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creatures = 0;
        n = _add(vs, n, "blind, no rescuer inside", _g(), p, 0, 0, Action.Evacuate);
        return n;
    }

    function _directedClose(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Default config: closeHoursAtMost = 6, closeStabilityBelow = 40.
        uint16[5] memory hrs = [uint16(0), 5, 6, 7, 24];
        for (uint256 i = 0; i < hrs.length; i++) {
            Portal memory p = _p();
            p.hoursToCollapse = hrs[i];
            n = _add(vs, n, "close: hours boundary (stable)", _g(), p, 0, 0, Action.Close);
        }
        uint8[4] memory stabs = [uint8(0), 39, 40, 41];
        for (uint256 i = 0; i < stabs.length; i++) {
            Portal memory p = _p();
            p.stability = stabs[i];
            n = _add(vs, n, "close: stability boundary (late)", _g(), p, 0, 0, Action.Close);
        }
        // Unsurveyed: the exact stability field must be ignored.
        Portal memory u = _p();
        u.surveyed = false;
        u.stability = 5;
        n = _add(vs, n, "close: unsurveyed, stability ignored", _g(), u, 0, 0, Action.Close);
        u = _p();
        u.surveyed = false;
        u.stability = 90;
        u.hoursToCollapse = 6;
        n = _add(vs, n, "close: unsurveyed, hours allow", _g(), u, 0, 0, Action.Close);
        // Zero thresholds (config 1): only hoursToCollapse == 0 passes.
        for (uint16 h = 0; h < 3; h++) {
            Portal memory z = _p();
            z.hoursToCollapse = h;
            z.stability = 0;
            n = _add(vs, n, "close: zero thresholds", _g(), z, 1, 0, Action.Close);
        }
        // Wide thresholds (config 2).
        Portal memory w = _p();
        w.hoursToCollapse = 48;
        n = _add(vs, n, "close: wide, hours 48", _g(), w, 2, 0, Action.Close);
        w = _p();
        w.hoursToCollapse = 49;
        w.stability = 99;
        n = _add(vs, n, "close: wide, stability 99", _g(), w, 2, 0, Action.Close);
        w = _p();
        w.hoursToCollapse = 49;
        w.stability = 100;
        n = _add(vs, n, "close: wide, stability 100", _g(), w, 2, 0, Action.Close);
        return n;
    }

    /// @dev The 84/85 gate: for each of the three risk paths find the smallest
    /// energy that turns the level Critical and emit it together with its
    /// predecessor, so a one-point drift in the mirror flips a vector.
    function _directedRiskGates(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        // Surveyed: stability 20, 12 h left, 1 creature, nobody inside → lives 1.
        uint8 e = 0;
        while (e <= 100 && RiskLib.levelOf(RiskLib.score(20, e, 12, 1)) != RiskLevel.Critical) e++;
        require(e > 0 && e <= 100, "no surveyed critical boundary");
        for (uint8 k = e - 1; k <= e; k++) {
            Portal memory p = _p();
            p.stability = 20;
            p.energy = k;
            p.hoursToCollapse = 12;
            p.creatures = 1;
            n = _add(vs, n, "gate: surveyed rescuer", _g(), p, 0, 0, Action.SendRescuer);
            p = _p();
            p.stability = 20;
            p.energy = k;
            p.hoursToCollapse = 12;
            p.creatures = 1;
            n = _add(vs, n, "gate: surveyed observer (lives 1)", _g(), p, 0, 0, Action.SendObserver);
        }

        // Cautious (unsurveyed rescuer): worst corner stabilityLo 20, creaturesHi 0 +
        // the rescuer itself → lives 1, 12 h.
        e = 0;
        while (e <= 100 && RiskLib.levelOf(RiskLib.score(20, e, 12, 1)) != RiskLevel.Critical) e++;
        for (uint8 k = e - 1; k <= e; k++) {
            Portal memory p = _p();
            p.surveyed = false;
            p.creaturesKnown = false;
            p.creatures = 0;
            p.stabilityLo = 20;
            p.stabilityHi = 30;
            p.energyHi = k;
            p.energyLo = 0;
            p.creaturesLo = 0;
            p.creaturesHi = 0;
            p.hoursToCollapse = 12;
            n = _add(vs, n, "gate: cautious rescuer", _g(), p, 0, 0, Action.SendRescuer);
        }
        return n;
    }

    // ── random vectors ───────────────────────────────────────────────────────

    function _r(uint256 i, string memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("portal-lab-rules-v1", i, tag)));
    }

    function _random(Vec[] memory vs, uint256 n) private pure returns (uint256) {
        for (uint256 i = 0; i < RANDOM_COUNT; i++) {
            Vec memory v = vs[n];
            v.label = "random";
            v.g = _randomGame(i);
            v.p = _randomPortal(i);
            v.cfg = uint8(_r(i, "cfg") % CONFIG_COUNT);
            uint256 sr = _r(i, "slot");
            v.slot = sr % 10 == 0 ? uint8(12 + (sr >> 8) % 244) : uint8((sr >> 8) % 12);
            v.a = Action(_r(i, "action") % 9);
            n++;
        }
        return n;
    }

    function _randomGame(uint256 i) private pure returns (Game memory g) {
        uint256 x = _r(i, "game");
        g.startedAt = x % 10 == 0 ? 0 : uint40(1000 + (x >> 8) % 100000);
        g.lastTickAt = uint40((x >> 24) % 200000);
        g.hoursElapsed = uint32((x >> 48) % 500);
        g.diedAtHour = uint32((x >> 64) % 500);
        g.hp = uint16((x >> 80) % 200);
        g.finished = (x >> 96) % 12 == 0;
        g.openPortals = uint8((x >> 100) % 13);
        g.spawnDebt = uint32((x >> 108) % 100000);
        g.spawnCount = uint32((x >> 128) % 1000);
        g.rngNonce = uint32((x >> 148) % 1000);
        g.creaturesRescued = uint32((x >> 168) % 100);
        g.settled = (x >> 190) % 5 == 0;

        uint256 y = _r(i, "game2");
        g.power = uint16(y % 3 == 0 ? (y >> 8) % 31 : (y >> 8) % 101);
        g.observersFree = (y >> 24) % 4 == 0 ? 0 : uint8(1 + (y >> 28) % 3);
        g.rescuersFree = (y >> 40) % 4 == 0 ? 0 : uint8(1 + (y >> 44) % 3);
        g.rescuerReadyAt0 = uint32((y >> 56) % 50);
        g.rescuerReadyAt1 = uint32((y >> 72) % 50);
        g.rescuerReadyAt2 = uint32((y >> 88) % 50);
        g.rescuerReadyAt3 = uint32((y >> 104) % 50);
    }

    function _randomPortal(uint256 i) private pure returns (Portal memory p) {
        uint256 x = _r(i, "portal");
        p.id = uint16((x >> 0) % 5000);
        p.portalType = PortalType((x >> 16) % 5);
        p.nameIndex = uint16((x >> 24) % 24);
        p.status = ((x >> 40) & 0xff) < 43 ? PortalStatus.Empty : ((x >> 48) % 2 == 0 ? PortalStatus.Open : PortalStatus.Questioned);
        p.surveyed = (x >> 56) % 2 == 0;
        p.observerInside = (x >> 60) % 4 == 0;
        p.rescuerInside = (x >> 64) % 4 == 0;
        p.surveyPending = (x >> 68) % 5 == 0;
        p.rescuerPending = (x >> 72) % 6 == 0;
        // A surveyed portal normally knows its count; unsurveyed may or may not.
        p.creaturesKnown = p.surveyed ? (x >> 76) % 8 != 0 : (x >> 76) % 3 == 0;
        p.spawnedAtHour = uint32((x >> 80) % 500);
        p.snapshotAt = uint40((x >> 100) % 200000);

        uint256 y = _r(i, "portal2");
        p.stability = uint8(y % 101);
        p.energy = uint8((y >> 8) % 101);
        p.creatures = (y >> 16) % 5 == 0 ? 0 : uint8((y >> 20) % 7);
        p.hoursToCollapse = (y >> 32) % 4 == 0 ? uint16((y >> 36) % 9) : uint16((y >> 36) % 61);

        uint256 z = _r(i, "portal3");
        p.stabilityLo = uint8(z % 101);
        p.stabilityHi = p.stabilityLo + uint8((z >> 8) % (101 - p.stabilityLo));
        p.energyLo = uint8((z >> 16) % 101);
        p.energyHi = p.energyLo + uint8((z >> 24) % (101 - p.energyLo));
        p.creaturesLo = uint8((z >> 32) % 5);
        p.creaturesHi = p.creaturesLo + uint8((z >> 40) % 5);
    }

    // ── coverage ─────────────────────────────────────────────────────────────

    function _requireCoverage(Vec[] memory vs, uint256 n, Config[] memory cfgs) private pure {
        bool[17] memory seenRefusal;
        bool[9] memory seenAction;
        for (uint256 i = 0; i < n; i++) {
            seenRefusal[uint8(RulesLib.check(vs[i].g, vs[i].p, cfgs[vs[i].cfg], vs[i].slot, vs[i].a))] = true;
            seenAction[uint8(vs[i].a)] = true;
        }
        for (uint256 r = 0; r < 17; r++) {
            if (r == uint256(Refusal.RandomnessTimeout)) continue; // never returned by check
            require(seenRefusal[r], "refusal code missing from vectors");
        }
        for (uint256 a = 0; a < 9; a++) {
            require(seenAction[a], "action missing from vectors");
        }
    }

    // ── output ───────────────────────────────────────────────────────────────

    function _head(Config[] memory cfgs) private pure returns (string memory) {
        string memory s = '{"configs":[';
        for (uint256 i = 0; i < cfgs.length; i++) {
            s = string.concat(s, i == 0 ? "" : ",", VectorCodec.configJson(cfgs[i]));
        }
        return string.concat(s, '],"vectors":[');
    }

    function _vectorLine(Vec memory v, Config[] memory cfgs, bool last) private view returns (string memory) {
        Refusal r = RulesLib.check(v.g, v.p, cfgs[v.cfg], v.slot, v.a);
        uint16 c = RulesLib.cost(cfgs[v.cfg], v.a);
        return string.concat(
            '{"label":"', v.label, '",',
            '"game":', VectorCodec.gameJson(v.g), ",",
            '"portal":', VectorCodec.portalJson(v.p), ",",
            VectorCodec.kv("config", v.cfg), ",",
            VectorCodec.kv("slot", v.slot), ",",
            VectorCodec.kv("action", uint8(v.a)), ",",
            '"expected":{', VectorCodec.kv("refusal", uint8(r)), ",", VectorCodec.kv("cost", c), "}}",
            last ? "" : ","
        );
    }

    function _m(string memory name, uint256 value, bool last) private pure returns (string memory) {
        return string.concat(VectorCodec.kv(name, value), last ? "" : ",");
    }

    /// @dev Member names are typed here by hand; the VALUES come from the compiled
    /// enums, and the member COUNT from `type(E).max`, so a member added to Solidity
    /// but forgotten here fails the `require` below instead of slipping through.
    function _enumsJson() private pure returns (string memory) {
        require(uint256(type(Action).max) + 1 == 9, "Action member count changed");
        require(uint256(type(Refusal).max) + 1 == 17, "Refusal member count changed");
        require(uint256(type(PortalType).max) + 1 == 5, "PortalType member count changed");
        require(uint256(type(PortalStatus).max) + 1 == 3, "PortalStatus member count changed");
        require(uint256(type(RiskLevel).max) + 1 == 6, "RiskLevel member count changed");

        string memory action = string.concat(
            "{",
            _m("ToggleQuestioned", uint8(Action.ToggleQuestioned), false),
            _m("Stabilize", uint8(Action.Stabilize), false),
            _m("Destabilize", uint8(Action.Destabilize), false),
            _m("SendObserver", uint8(Action.SendObserver), false),
            _m("RecallObserver", uint8(Action.RecallObserver), false),
            _m("SendRescuer", uint8(Action.SendRescuer), false),
            _m("RecallRescuer", uint8(Action.RecallRescuer), false),
            _m("Evacuate", uint8(Action.Evacuate), false),
            _m("Close", uint8(Action.Close), true),
            "}"
        );
        string memory refusal = string.concat(
            "{",
            _m("None", uint8(Refusal.None), false),
            _m("GameNotActive", uint8(Refusal.GameNotActive), false),
            _m("InvalidSlot", uint8(Refusal.InvalidSlot), false),
            _m("PortalEmpty", uint8(Refusal.PortalEmpty), false),
            _m("NotSurveyed", uint8(Refusal.NotSurveyed), false),
            _m("SurveyPending", uint8(Refusal.SurveyPending), false),
            _m("ObserverAlreadyInside", uint8(Refusal.ObserverAlreadyInside), false),
            _m("NoObserverInside", uint8(Refusal.NoObserverInside), false),
            _m("NoObserverFree", uint8(Refusal.NoObserverFree), false),
            _m("RescuerAlreadyInside", uint8(Refusal.RescuerAlreadyInside), false),
            _m("NoRescuerInside", uint8(Refusal.NoRescuerInside), false),
            _m("NoRescuerFree", uint8(Refusal.NoRescuerFree), false),
            _m("NoCreatures", uint8(Refusal.NoCreatures), false),
            _m("RiskTooHigh", uint8(Refusal.RiskTooHigh), false),
            _m("NotUnstableEnough", uint8(Refusal.NotUnstableEnough), false),
            _m("NotEnoughPower", uint8(Refusal.NotEnoughPower), false),
            _m("RandomnessTimeout", uint8(Refusal.RandomnessTimeout), true),
            "}"
        );
        string memory portalType = string.concat(
            "{",
            _m("Flash", uint8(PortalType.Flash), false),
            _m("LongLived", uint8(PortalType.LongLived), false),
            _m("Deaf", uint8(PortalType.Deaf), false),
            _m("Resonant", uint8(PortalType.Resonant), false),
            _m("Energetic", uint8(PortalType.Energetic), true),
            "}"
        );
        string memory portalStatus = string.concat(
            "{",
            _m("Empty", uint8(PortalStatus.Empty), false),
            _m("Open", uint8(PortalStatus.Open), false),
            _m("Questioned", uint8(PortalStatus.Questioned), true),
            "}"
        );
        string memory riskLevel = string.concat(
            "{",
            _m("Unknown", uint8(RiskLevel.Unknown), false),
            _m("None", uint8(RiskLevel.None), false),
            _m("Low", uint8(RiskLevel.Low), false),
            _m("Medium", uint8(RiskLevel.Medium), false),
            _m("High", uint8(RiskLevel.High), false),
            _m("Critical", uint8(RiskLevel.Critical), true),
            "}"
        );
        return string.concat(
            '{"Action":', action, ',"Refusal":', refusal, ',"PortalType":', portalType,
            ',"PortalStatus":', portalStatus, ',"RiskLevel":', riskLevel, "}\n"
        );
    }
}
