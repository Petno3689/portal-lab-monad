// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Game, Portal, Config, PortalTypeParams, PortalType, PortalStatus} from "../../src/PortalLabTypes.sol";
import {EffectsLib, NoFreeRescuerCell} from "../../src/EffectsLib.sol";
import {TimeLib} from "../../src/TimeLib.sol";

/// @title VectorCodec — JSON (de)serialisation of the game structs for golden vectors.
/// @notice Shared by the generator scripts (write side) and the golden tests (read
/// side) so both agree on field names. The file format is described in
/// shared/test/support/vectorFormat.ts — the TS side of the same contract.
///
/// Write side: one compact JSON object per struct, fixed field order, no spaces.
/// Read side: COLUMN-wise. `readGames(json, ".vectors[*].game")` pulls every field
/// of every game with one wildcard path per field. Whole-struct `vm.parseJson`
/// decoding is deliberately avoided: it maps keys alphabetically onto the struct,
/// which silently scrambles fields if the struct order is not alphabetical.
library VectorCodec {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ── write ────────────────────────────────────────────────────────────────

    function kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat('"', k, '":', vm.toString(v));
    }

    function kb(string memory k, bool v) internal pure returns (string memory) {
        return string.concat('"', k, '":', v ? "true" : "false");
    }

    function gameJson(Game memory g) internal pure returns (string memory) {
        return string.concat(
            "{",
            kv("startedAt", g.startedAt), ",",
            kv("lastTickAt", g.lastTickAt), ",",
            kv("hoursElapsed", g.hoursElapsed), ",",
            kv("diedAtHour", g.diedAtHour), ",",
            kv("hp", g.hp), ",",
            kv("power", g.power), ",",
            kv("observersFree", g.observersFree), ",",
            kv("rescuersFree", g.rescuersFree), ",",
            kv("openPortals", g.openPortals), ",",
            kb("finished", g.finished), ",",
            kv("spawnDebt", g.spawnDebt), ",",
            kv("spawnCount", g.spawnCount), ",",
            kv("rngNonce", g.rngNonce), ",",
            kv("rescuerReadyAt0", g.rescuerReadyAt0), ",",
            kv("rescuerReadyAt1", g.rescuerReadyAt1), ",",
            kv("rescuerReadyAt2", g.rescuerReadyAt2), ",",
            kv("rescuerReadyAt3", g.rescuerReadyAt3), ",",
            kv("creaturesRescued", g.creaturesRescued), ",",
            kb("settled", g.settled),
            "}"
        );
    }

    function portalJson(Portal memory p) internal pure returns (string memory) {
        string memory a = string.concat(
            kv("id", p.id), ",",
            kv("portalType", uint8(p.portalType)), ",",
            kv("nameIndex", p.nameIndex), ",",
            kv("status", uint8(p.status)), ",",
            kb("surveyed", p.surveyed), ",",
            kb("narrowedOnce", p.narrowedOnce), ",",
            kb("observerInside", p.observerInside), ",",
            kb("rescuerInside", p.rescuerInside), ",",
            kb("surveyPending", p.surveyPending), ",",
            kb("rescuerPending", p.rescuerPending), ",",
            kb("creaturesKnown", p.creaturesKnown)
        );
        string memory b = string.concat(
            kv("energy", p.energy), ",",
            kv("stability", p.stability), ",",
            kv("creatures", p.creatures), ",",
            kv("hoursToCollapse", p.hoursToCollapse), ",",
            kv("spawnedAtHour", p.spawnedAtHour), ",",
            kv("snapshotAt", p.snapshotAt), ",",
            kv("energyLo", p.energyLo), ",",
            kv("energyHi", p.energyHi), ",",
            kv("stabilityLo", p.stabilityLo), ",",
            kv("stabilityHi", p.stabilityHi), ",",
            kv("creaturesLo", p.creaturesLo), ",",
            kv("creaturesHi", p.creaturesHi)
        );
        return string.concat("{", a, ",", b, "}");
    }

    function configJson(Config memory c) internal pure returns (string memory) {
        string memory a = string.concat(
            kv("secPerHour", c.secPerHour), ",",
            kv("longAbsenceHours", c.longAbsenceHours), ",",
            kv("hpMax", c.hpMax), ",",
            kv("hpStart", c.hpStart), ",",
            kv("hpCollapseBase", c.hpCollapseBase), ",",
            kv("hpCollapsePerDeath", c.hpCollapsePerDeath), ",",
            kv("hpEmptyCollapse", c.hpEmptyCollapse), ",",
            kv("hpOverflowPerHour", c.hpOverflowPerHour), ",",
            kv("healPerCreature", c.healPerCreature), ",",
            kv("powerMax", c.powerMax), ",",
            kv("powerRegenPerHour", c.powerRegenPerHour)
        );
        string memory b = string.concat(
            kv("costToggleQuestioned", c.costToggleQuestioned), ",",
            kv("costStabilize", c.costStabilize), ",",
            kv("costDestabilize", c.costDestabilize), ",",
            kv("costSendObserver", c.costSendObserver), ",",
            kv("costRecallObserver", c.costRecallObserver), ",",
            kv("costSendRescuer", c.costSendRescuer), ",",
            kv("costRecallRescuer", c.costRecallRescuer), ",",
            kv("costEvacuate", c.costEvacuate), ",",
            kv("costClose", c.costClose)
        );
        string memory d = string.concat(
            kv("observersTotal", c.observersTotal), ",",
            kv("rescuersTotal", c.rescuersTotal), ",",
            kv("rescuerCooldownHours", c.rescuerCooldownHours), ",",
            kv("closeStabilityBelow", c.closeStabilityBelow), ",",
            kv("closeHoursAtMost", c.closeHoursAtMost), ",",
            kv("basePressurePerHour", c.basePressurePerHour), ",",
            kv("pressureRampPerHour", c.pressureRampPerHour), ",",
            kv("spawnCostUnits", c.spawnCostUnits), ",",
            kv("closePressureBonus", c.closePressureBonus), ",",
            kv("rangeWidenPerHour", c.rangeWidenPerHour), ",",
            kv("epochHours", c.epochHours), ",",
            kv("requestTimeoutHours", c.requestTimeoutHours), ",",
            kv("outsiderTimeoutHours", c.outsiderTimeoutHours)
        );
        return string.concat("{", a, ",", b, ",", d, "}");
    }

    function typeParamsJson(PortalTypeParams memory t) internal pure returns (string memory) {
        return string.concat(
            "{",
            kv("hoursMin", t.hoursMin), ",",
            kv("hoursMax", t.hoursMax), ",",
            kv("degradePerHour", t.degradePerHour), ",",
            kv("energyMin", t.energyMin), ",",
            kv("energyMax", t.energyMax), ",",
            kv("stabilityMin", t.stabilityMin), ",",
            kv("stabilityMax", t.stabilityMax), ",",
            kv("creaturesMin", t.creaturesMin), ",",
            kv("creaturesMax", t.creaturesMax), ",",
            kv("actionMultiplierPct", t.actionMultiplierPct), ",",
            kv("powerYieldPerHour", t.powerYieldPerHour), ",",
            kb("surveyPrecise", t.surveyPrecise),
            "}"
        );
    }

    /// @dev One `TimeLib.Collapse`. Written only for the first `eventCount` entries
    /// of the fixed-size return array — the tail is uninitialised memory and
    /// recording it would make a golden test compare rubbish.
    function collapseJson(TimeLib.Collapse memory e) internal pure returns (string memory) {
        return string.concat(
            "{",
            kv("slot", e.slot), ",",
            kv("deaths", e.deaths), ",",
            kv("hpLost", e.hpLost), ",",
            kv("atHour", e.atHour),
            "}"
        );
    }

    /// @dev One `TimeLib.Spawn`. Same "first `spawnCount` entries only" rule as
    /// `collapseJson`.
    function spawnJson(TimeLib.Spawn memory s) internal pure returns (string memory) {
        return string.concat(
            "{",
            kv("slot", s.slot), ",",
            kv("portalType", uint8(s.portalType)), ",",
            kv("nameIndex", s.nameIndex), ",",
            kv("atHour", s.atHour),
            "}"
        );
    }

    function outcomeJson(EffectsLib.Outcome memory o) internal pure returns (string memory) {
        return string.concat(
            "{",
            kv("rescued", o.rescued), ",",
            kv("hpGained", o.hpGained), ",",
            kv("deaths", o.deaths), ",",
            kv("hpLost", o.hpLost), ",",
            kb("surveyDone", o.surveyDone), ",",
            kb("surveyPrecise", o.surveyPrecise), ",",
            kb("rescuerBlindMiss", o.rescuerBlindMiss), ",",
            kv("rescuerReadyAtHour", o.rescuerReadyAtHour), ",",
            kv("leftBehind", o.leftBehind),
            "}"
        );
    }

    /// @dev A uint256 as a quoted decimal string (format rule 4: wide values are strings).
    function ks(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat('"', k, '":"', vm.toString(v), '"');
    }

    /// @dev Name of a revert, as recorded in the vector files. Reverts (the generator /
    /// test) when it meets a kind the format does not name (see vectorFormat.ts).
    function errorName(bytes memory err) internal pure returns (string memory) {
        require(err.length >= 4, "VectorCodec: empty revert data");
        bytes4 sel = bytes4(err);
        if (sel == NoFreeRescuerCell.selector) return "NoFreeRescuerCell";
        if (sel == bytes4(0x4e487b71) && err.length == 36) {
            // Panic(uint256): the code is the 32 bytes after the selector.
            bytes memory tail = new bytes(32);
            for (uint256 i = 0; i < 32; i++) {
                tail[i] = err[4 + i];
            }
            if (abi.decode(tail, (uint256)) == 0x11) return "Panic(0x11)";
        }
        revert("VectorCodec: revert kind not named in vectorFormat.ts");
    }

    // ── read ─────────────────────────────────────────────────────────────────

    function _u(string memory json, string memory path, string memory f) private pure returns (uint256[] memory) {
        return abi.decode(vm.parseJson(json, string.concat(path, ".", f)), (uint256[]));
    }

    function _b(string memory json, string memory path, string memory f) private pure returns (bool[] memory) {
        return abi.decode(vm.parseJson(json, string.concat(path, ".", f)), (bool[]));
    }

    /// @param path JSON path to the objects, ending in a wildcard, e.g. ".vectors[*].game".
    function readGames(string memory json, string memory path) internal pure returns (Game[] memory out) {
        uint256[] memory startedAt = _u(json, path, "startedAt");
        uint256 n = startedAt.length;
        out = new Game[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i].startedAt = uint40(startedAt[i]);
        }
        _readGamesA(json, path, out);
        _readGamesB(json, path, out);
    }

    function _readGamesA(string memory json, string memory path, Game[] memory out) private pure {
        uint256[] memory lastTickAt = _u(json, path, "lastTickAt");
        uint256[] memory hoursElapsed = _u(json, path, "hoursElapsed");
        uint256[] memory diedAtHour = _u(json, path, "diedAtHour");
        uint256[] memory hp = _u(json, path, "hp");
        uint256[] memory power = _u(json, path, "power");
        uint256[] memory observersFree = _u(json, path, "observersFree");
        uint256[] memory rescuersFree = _u(json, path, "rescuersFree");
        uint256[] memory openPortals = _u(json, path, "openPortals");
        bool[] memory finished = _b(json, path, "finished");
        for (uint256 i = 0; i < out.length; i++) {
            Game memory g = out[i];
            g.lastTickAt = uint40(lastTickAt[i]);
            g.hoursElapsed = uint32(hoursElapsed[i]);
            g.diedAtHour = uint32(diedAtHour[i]);
            g.hp = uint16(hp[i]);
            g.power = uint16(power[i]);
            g.observersFree = uint8(observersFree[i]);
            g.rescuersFree = uint8(rescuersFree[i]);
            g.openPortals = uint8(openPortals[i]);
            g.finished = finished[i];
        }
    }

    function _readGamesB(string memory json, string memory path, Game[] memory out) private pure {
        uint256[] memory spawnDebt = _u(json, path, "spawnDebt");
        uint256[] memory spawnCount = _u(json, path, "spawnCount");
        uint256[] memory rngNonce = _u(json, path, "rngNonce");
        uint256[] memory r0 = _u(json, path, "rescuerReadyAt0");
        uint256[] memory r1 = _u(json, path, "rescuerReadyAt1");
        uint256[] memory r2 = _u(json, path, "rescuerReadyAt2");
        uint256[] memory r3 = _u(json, path, "rescuerReadyAt3");
        uint256[] memory creaturesRescued = _u(json, path, "creaturesRescued");
        bool[] memory settled = _b(json, path, "settled");
        for (uint256 i = 0; i < out.length; i++) {
            Game memory g = out[i];
            g.spawnDebt = uint32(spawnDebt[i]);
            g.spawnCount = uint32(spawnCount[i]);
            g.rngNonce = uint32(rngNonce[i]);
            g.rescuerReadyAt0 = uint32(r0[i]);
            g.rescuerReadyAt1 = uint32(r1[i]);
            g.rescuerReadyAt2 = uint32(r2[i]);
            g.rescuerReadyAt3 = uint32(r3[i]);
            g.creaturesRescued = uint32(creaturesRescued[i]);
            g.settled = settled[i];
        }
    }

    function readPortals(string memory json, string memory path) internal pure returns (Portal[] memory out) {
        uint256[] memory id = _u(json, path, "id");
        out = new Portal[](id.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i].id = uint16(id[i]);
        }
        _readPortalsA(json, path, out);
        _readPortalsB(json, path, out);
    }

    function _readPortalsA(string memory json, string memory path, Portal[] memory out) private pure {
        uint256[] memory portalType = _u(json, path, "portalType");
        uint256[] memory nameIndex = _u(json, path, "nameIndex");
        uint256[] memory status = _u(json, path, "status");
        bool[] memory surveyed = _b(json, path, "surveyed");
        bool[] memory narrowedOnce = _b(json, path, "narrowedOnce");
        bool[] memory observerInside = _b(json, path, "observerInside");
        bool[] memory rescuerInside = _b(json, path, "rescuerInside");
        bool[] memory surveyPending = _b(json, path, "surveyPending");
        bool[] memory rescuerPending = _b(json, path, "rescuerPending");
        bool[] memory creaturesKnown = _b(json, path, "creaturesKnown");
        for (uint256 i = 0; i < out.length; i++) {
            Portal memory p = out[i];
            p.portalType = PortalType(portalType[i]);
            p.nameIndex = uint8(nameIndex[i]);
            p.status = PortalStatus(status[i]);
            p.surveyed = surveyed[i];
            p.narrowedOnce = narrowedOnce[i];
            p.observerInside = observerInside[i];
            p.rescuerInside = rescuerInside[i];
            p.surveyPending = surveyPending[i];
            p.rescuerPending = rescuerPending[i];
            p.creaturesKnown = creaturesKnown[i];
        }
    }

    function _readPortalsB(string memory json, string memory path, Portal[] memory out) private pure {
        uint256[] memory energy = _u(json, path, "energy");
        uint256[] memory stability = _u(json, path, "stability");
        uint256[] memory creatures = _u(json, path, "creatures");
        uint256[] memory hoursToCollapse = _u(json, path, "hoursToCollapse");
        uint256[] memory spawnedAtHour = _u(json, path, "spawnedAtHour");
        uint256[] memory snapshotAt = _u(json, path, "snapshotAt");
        uint256[] memory energyLo = _u(json, path, "energyLo");
        uint256[] memory energyHi = _u(json, path, "energyHi");
        uint256[] memory stabilityLo = _u(json, path, "stabilityLo");
        uint256[] memory stabilityHi = _u(json, path, "stabilityHi");
        uint256[] memory creaturesLo = _u(json, path, "creaturesLo");
        uint256[] memory creaturesHi = _u(json, path, "creaturesHi");
        for (uint256 i = 0; i < out.length; i++) {
            Portal memory p = out[i];
            p.energy = uint8(energy[i]);
            p.stability = uint8(stability[i]);
            p.creatures = uint8(creatures[i]);
            p.hoursToCollapse = uint16(hoursToCollapse[i]);
            p.spawnedAtHour = uint32(spawnedAtHour[i]);
            p.snapshotAt = uint40(snapshotAt[i]);
            p.energyLo = uint8(energyLo[i]);
            p.energyHi = uint8(energyHi[i]);
            p.stabilityLo = uint8(stabilityLo[i]);
            p.stabilityHi = uint8(stabilityHi[i]);
            p.creaturesLo = uint8(creaturesLo[i]);
            p.creaturesHi = uint8(creaturesHi[i]);
        }
    }

    function readConfigs(string memory json, string memory path) internal pure returns (Config[] memory out) {
        uint256[] memory secPerHour = _u(json, path, "secPerHour");
        out = new Config[](secPerHour.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i].secPerHour = uint32(secPerHour[i]);
        }
        _readConfigsA(json, path, out);
        _readConfigsB(json, path, out);
        _readConfigsC(json, path, out);
    }

    function _readConfigsA(string memory json, string memory path, Config[] memory out) private pure {
        uint256[] memory longAbsenceHours = _u(json, path, "longAbsenceHours");
        uint256[] memory hpMax = _u(json, path, "hpMax");
        uint256[] memory hpStart = _u(json, path, "hpStart");
        uint256[] memory hpCollapseBase = _u(json, path, "hpCollapseBase");
        uint256[] memory hpCollapsePerDeath = _u(json, path, "hpCollapsePerDeath");
        uint256[] memory hpEmptyCollapse = _u(json, path, "hpEmptyCollapse");
        uint256[] memory hpOverflowPerHour = _u(json, path, "hpOverflowPerHour");
        uint256[] memory healPerCreature = _u(json, path, "healPerCreature");
        uint256[] memory powerMax = _u(json, path, "powerMax");
        uint256[] memory powerRegenPerHour = _u(json, path, "powerRegenPerHour");
        for (uint256 i = 0; i < out.length; i++) {
            Config memory c = out[i];
            c.longAbsenceHours = uint16(longAbsenceHours[i]);
            c.hpMax = uint16(hpMax[i]);
            c.hpStart = uint16(hpStart[i]);
            c.hpCollapseBase = uint16(hpCollapseBase[i]);
            c.hpCollapsePerDeath = uint16(hpCollapsePerDeath[i]);
            c.hpEmptyCollapse = uint16(hpEmptyCollapse[i]);
            c.hpOverflowPerHour = uint16(hpOverflowPerHour[i]);
            c.healPerCreature = uint16(healPerCreature[i]);
            c.powerMax = uint16(powerMax[i]);
            c.powerRegenPerHour = uint16(powerRegenPerHour[i]);
        }
    }

    function _readConfigsB(string memory json, string memory path, Config[] memory out) private pure {
        uint256[] memory c0 = _u(json, path, "costToggleQuestioned");
        uint256[] memory c1 = _u(json, path, "costStabilize");
        uint256[] memory c2 = _u(json, path, "costDestabilize");
        uint256[] memory c3 = _u(json, path, "costSendObserver");
        uint256[] memory c4 = _u(json, path, "costRecallObserver");
        uint256[] memory c5 = _u(json, path, "costSendRescuer");
        uint256[] memory c6 = _u(json, path, "costRecallRescuer");
        uint256[] memory c7 = _u(json, path, "costEvacuate");
        uint256[] memory c8 = _u(json, path, "costClose");
        uint256[] memory observersTotal = _u(json, path, "observersTotal");
        uint256[] memory rescuersTotal = _u(json, path, "rescuersTotal");
        uint256[] memory rescuerCooldownHours = _u(json, path, "rescuerCooldownHours");
        for (uint256 i = 0; i < out.length; i++) {
            Config memory c = out[i];
            c.costToggleQuestioned = uint16(c0[i]);
            c.costStabilize = uint16(c1[i]);
            c.costDestabilize = uint16(c2[i]);
            c.costSendObserver = uint16(c3[i]);
            c.costRecallObserver = uint16(c4[i]);
            c.costSendRescuer = uint16(c5[i]);
            c.costRecallRescuer = uint16(c6[i]);
            c.costEvacuate = uint16(c7[i]);
            c.costClose = uint16(c8[i]);
            c.observersTotal = uint8(observersTotal[i]);
            c.rescuersTotal = uint8(rescuersTotal[i]);
            c.rescuerCooldownHours = uint16(rescuerCooldownHours[i]);
        }
    }

    function _readConfigsC(string memory json, string memory path, Config[] memory out) private pure {
        uint256[] memory closeStabilityBelow = _u(json, path, "closeStabilityBelow");
        uint256[] memory closeHoursAtMost = _u(json, path, "closeHoursAtMost");
        uint256[] memory basePressurePerHour = _u(json, path, "basePressurePerHour");
        uint256[] memory pressureRampPerHour = _u(json, path, "pressureRampPerHour");
        uint256[] memory spawnCostUnits = _u(json, path, "spawnCostUnits");
        uint256[] memory closePressureBonus = _u(json, path, "closePressureBonus");
        uint256[] memory rangeWidenPerHour = _u(json, path, "rangeWidenPerHour");
        uint256[] memory epochHours = _u(json, path, "epochHours");
        uint256[] memory requestTimeoutHours = _u(json, path, "requestTimeoutHours");
        uint256[] memory outsiderTimeoutHours = _u(json, path, "outsiderTimeoutHours");
        for (uint256 i = 0; i < out.length; i++) {
            Config memory c = out[i];
            c.closeStabilityBelow = uint8(closeStabilityBelow[i]);
            c.closeHoursAtMost = uint16(closeHoursAtMost[i]);
            c.basePressurePerHour = uint32(basePressurePerHour[i]);
            c.pressureRampPerHour = uint32(pressureRampPerHour[i]);
            c.spawnCostUnits = uint32(spawnCostUnits[i]);
            c.closePressureBonus = uint32(closePressureBonus[i]);
            c.rangeWidenPerHour = uint8(rangeWidenPerHour[i]);
            c.epochHours = uint16(epochHours[i]);
            c.requestTimeoutHours = uint16(requestTimeoutHours[i]);
            c.outsiderTimeoutHours = uint16(outsiderTimeoutHours[i]);
        }
    }

    function readTypeParams(string memory json, string memory path)
        internal
        pure
        returns (PortalTypeParams[] memory out)
    {
        uint256[] memory hoursMin = _u(json, path, "hoursMin");
        out = new PortalTypeParams[](hoursMin.length);
        uint256[] memory hoursMax = _u(json, path, "hoursMax");
        uint256[] memory degradePerHour = _u(json, path, "degradePerHour");
        uint256[] memory energyMin = _u(json, path, "energyMin");
        uint256[] memory energyMax = _u(json, path, "energyMax");
        uint256[] memory stabilityMin = _u(json, path, "stabilityMin");
        uint256[] memory stabilityMax = _u(json, path, "stabilityMax");
        uint256[] memory creaturesMin = _u(json, path, "creaturesMin");
        uint256[] memory creaturesMax = _u(json, path, "creaturesMax");
        uint256[] memory mult = _u(json, path, "actionMultiplierPct");
        uint256[] memory yieldPerHour = _u(json, path, "powerYieldPerHour");
        bool[] memory precise = _b(json, path, "surveyPrecise");
        for (uint256 i = 0; i < out.length; i++) {
            PortalTypeParams memory t = out[i];
            t.hoursMin = uint16(hoursMin[i]);
            t.hoursMax = uint16(hoursMax[i]);
            t.degradePerHour = uint8(degradePerHour[i]);
            t.energyMin = uint8(energyMin[i]);
            t.energyMax = uint8(energyMax[i]);
            t.stabilityMin = uint8(stabilityMin[i]);
            t.stabilityMax = uint8(stabilityMax[i]);
            t.creaturesMin = uint8(creaturesMin[i]);
            t.creaturesMax = uint8(creaturesMax[i]);
            t.actionMultiplierPct = uint16(mult[i]);
            t.powerYieldPerHour = uint8(yieldPerHour[i]);
            t.surveyPrecise = precise[i];
        }
    }

    function readOutcomes(string memory json, string memory path)
        internal
        pure
        returns (EffectsLib.Outcome[] memory out)
    {
        uint256[] memory rescued = _u(json, path, "rescued");
        out = new EffectsLib.Outcome[](rescued.length);
        uint256[] memory hpGained = _u(json, path, "hpGained");
        uint256[] memory deaths = _u(json, path, "deaths");
        uint256[] memory hpLost = _u(json, path, "hpLost");
        bool[] memory surveyDone = _b(json, path, "surveyDone");
        bool[] memory surveyPrecise = _b(json, path, "surveyPrecise");
        bool[] memory blindMiss = _b(json, path, "rescuerBlindMiss");
        uint256[] memory readyAt = _u(json, path, "rescuerReadyAtHour");
        uint256[] memory leftBehind = _u(json, path, "leftBehind");
        for (uint256 i = 0; i < out.length; i++) {
            EffectsLib.Outcome memory o = out[i];
            o.rescued = uint8(rescued[i]);
            o.hpGained = uint16(hpGained[i]);
            o.deaths = uint8(deaths[i]);
            o.hpLost = uint16(hpLost[i]);
            o.surveyDone = surveyDone[i];
            o.surveyPrecise = surveyPrecise[i];
            o.rescuerBlindMiss = blindMiss[i];
            o.rescuerReadyAtHour = uint32(readyAt[i]);
            o.leftBehind = uint8(leftBehind[i]);
        }
    }

    /// @dev Column of `TimeLib.Collapse` records. The path may carry TWO wildcards
    /// (`.vectors[*].expected.events[*]`), in which case the per-vector arrays come
    /// back FLATTENED in vector order; the caller walks them with a running offset
    /// and the counts its own call to the library returned. A path matching NOTHING
    /// (every vector's array empty) makes `vm.parseJson` return zero bytes and the
    /// decode below revert — check for that case before calling.
    function readCollapses(string memory json, string memory path)
        internal
        pure
        returns (TimeLib.Collapse[] memory out)
    {
        uint256[] memory slot = _u(json, path, "slot");
        uint256[] memory deaths = _u(json, path, "deaths");
        uint256[] memory hpLost = _u(json, path, "hpLost");
        uint256[] memory atHour = _u(json, path, "atHour");
        out = new TimeLib.Collapse[](slot.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i].slot = uint8(slot[i]);
            out[i].deaths = uint8(deaths[i]);
            out[i].hpLost = uint16(hpLost[i]);
            out[i].atHour = uint32(atHour[i]);
        }
    }

    /// @dev Column of `TimeLib.Spawn` records, with exactly the same flattening and
    /// empty-path caveats as `readCollapses`.
    function readSpawns(string memory json, string memory path) internal pure returns (TimeLib.Spawn[] memory out) {
        uint256[] memory slot = _u(json, path, "slot");
        uint256[] memory portalType = _u(json, path, "portalType");
        uint256[] memory nameIndex = _u(json, path, "nameIndex");
        uint256[] memory atHour = _u(json, path, "atHour");
        out = new TimeLib.Spawn[](slot.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i].slot = uint8(slot[i]);
            out[i].portalType = PortalType(portalType[i]);
            out[i].nameIndex = uint8(nameIndex[i]);
            out[i].atHour = uint32(atHour[i]);
        }
    }

    /// @dev A whole-path column of numbers (any path, not only struct fields).
    function readUints(string memory json, string memory path) internal pure returns (uint256[] memory) {
        return abi.decode(vm.parseJson(json, path), (uint256[]));
    }

    function readBools(string memory json, string memory path) internal pure returns (bool[] memory) {
        return abi.decode(vm.parseJson(json, path), (bool[]));
    }

    function readStrings(string memory json, string memory path) internal pure returns (string[] memory) {
        return abi.decode(vm.parseJson(json, path), (string[]));
    }

    /// @dev Column of uint256 values written as decimal STRINGS (format rule 4), read ROW
    /// BY ROW. The wildcard form (`[*]`) is unusable here: Foundry infers a type for
    /// each numeric-looking string and, depending on the values in the column, hands
    /// the array back as uint256[], string[] or something in between. Asking for one
    /// string at a time is unambiguous; the price is one re-parse of the file per row.
    /// `arrayPath` is e.g. ".survey" and `n` the row count.
    function readWords(string memory json, string memory arrayPath, uint256 n) internal pure returns (uint256[] memory) {
        return readWordField(json, arrayPath, "word", n);
    }

    /// @dev `readWords` for a row member under another name — a vector carrying two
    /// words (`oldWord` / `newWord`) needs one column per name.
    function readWordField(string memory json, string memory arrayPath, string memory field, uint256 n)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory path = string.concat(arrayPath, "[", vm.toString(i), "].", field);
            out[i] = vm.parseUint(vm.parseJsonString(json, path));
        }
    }
}
