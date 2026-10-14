// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Config, PortalTypeParams} from "./PortalLabTypes.sol";

/// @title GameConfig — the ONE canonical source of deployment parameters.
/// @notice All numeric balance values live here and nowhere else. They have been
/// validated by a 128-seed dualSimulation sweep (IdealGame.t.sol). Do not edit
/// these numbers without re-running the sweep and updating the test expectations.
/// The script/Deploy.s.sol and test/utils/DefaultConfig.sol both delegate here.
library GameConfig {
    /// @notice Canonical game configuration for deployment.
    function config() internal pure returns (Config memory c) {
        // time
        c.secPerHour = 15;
        c.longAbsenceHours = 20;
        // HP
        c.hpMax = 100;
        c.hpStart = 50;
        c.hpCollapseBase = 20;
        c.hpCollapsePerDeath = 10;
        c.hpEmptyCollapse = 3;
        c.hpOverflowPerHour = 5;
        c.healPerCreature = 3;
        // resource
        c.powerMax = 100;
        c.powerRegenPerHour = 5;
        // action costs
        c.costToggleQuestioned = 0;
        c.costStabilize = 5;
        c.costDestabilize = 5;
        c.costSendObserver = 10;
        c.costRecallObserver = 5;
        c.costSendRescuer = 20;
        c.costRecallRescuer = 10;
        c.costEvacuate = 10;
        c.costClose = 25;
        // crew
        c.observersTotal = 3;
        c.rescuersTotal = 2;
        c.rescuerCooldownHours = 10;
        // closing thresholds
        c.closeStabilityBelow = 40;
        c.closeHoursAtMost = 6;
        // spawns — pressure measured in units; one portal costs spawnCostUnits units.
        // A fresh lab accrues ~one portal's worth of pressure per ten game hours,
        // the ramp speeds that up over the run, and closing grants 1/4 of a portal.
        c.basePressurePerHour = 1000;
        c.pressureRampPerHour = 1;
        c.spawnCostUnits = 10_000;
        c.closePressureBonus = 2500;
        // survey / knowledge decay
        c.rangeWidenPerHour = 1;
        // spawn entropy — one random word pinned per 36 game-hour epoch (Ticket 4.5).
        c.epochHours = 36;
        // a deferral stuck this long (real time) can be cancelled by its player (Ticket 4.7);
        // anyone else must wait the longer outsider timeout (40 h = 10 real minutes).
        c.requestTimeoutHours = 1;
        c.outsiderTimeoutHours = 40;
    }

    /// @notice Canonical per-type parameters, one per `PortalType`, in enum order.
    /// Columns: hours, degrade, energy, stability, creatures, multiplier, yield,
    /// precise.
    function portalTypeParams() internal pure returns (PortalTypeParams[5] memory p) {
        // Flash: 5–10h, 6deg, 60–100 energy, 20–60 stability, 1–3 creatures, 100%, 0, true.
        // creaturesMin is 1 (not 2): a flash with one creature is a real stake —
        // a blind evacuation saves nobody. Mid = (1+3)/2 = 2, same as (2+3)/2 = 2
        // (integer division), so expected rescue value and HP math are preserved.
        p[0] = PortalTypeParams({
            hoursMin: 5,
            hoursMax: 10,
            degradePerHour: 6,
            energyMin: 60,
            energyMax: 100,
            stabilityMin: 20,
            stabilityMax: 60,
            creaturesMin: 1,
            creaturesMax: 3,
            actionMultiplierPct: 100,
            powerYieldPerHour: 0,
            surveyPrecise: true
        });
        // LongLived: 30–60, 2, 20–60, 40–90, 1–5, 100, 0, true.
        // creaturesMin is 1 (not 2): same stake logic as Flash.
        // Mid = (1+5)/2 = 3, same as (2+5)/2 = 3 (integer division preserves midpoint).
        p[1] = PortalTypeParams({
            hoursMin: 30,
            hoursMax: 60,
            degradePerHour: 2,
            energyMin: 20,
            energyMax: 60,
            stabilityMin: 40,
            stabilityMax: 90,
            creaturesMin: 1,
            creaturesMax: 5,
            actionMultiplierPct: 100,
            powerYieldPerHour: 0,
            surveyPrecise: true
        });
        // Deaf: 10–30, 3, 20–100, 10–90, 0–4, 100, 0, false
        p[2] = PortalTypeParams({
            hoursMin: 10,
            hoursMax: 30,
            degradePerHour: 3,
            energyMin: 20,
            energyMax: 100,
            stabilityMin: 10,
            stabilityMax: 90,
            creaturesMin: 0,
            creaturesMax: 4,
            actionMultiplierPct: 100,
            powerYieldPerHour: 0,
            surveyPrecise: false
        });
        // Resonant: 10–30, 5, 30–80, 20–80, 0–3, 200, 0, true
        p[3] = PortalTypeParams({
            hoursMin: 10,
            hoursMax: 30,
            degradePerHour: 5,
            energyMin: 30,
            energyMax: 80,
            stabilityMin: 20,
            stabilityMax: 80,
            creaturesMin: 0,
            creaturesMax: 3,
            actionMultiplierPct: 200,
            powerYieldPerHour: 0,
            surveyPrecise: true
        });
        // Energetic: 10–30, 3, 60–100, 20–70, 0–2, 100, 4, true
        p[4] = PortalTypeParams({
            hoursMin: 10,
            hoursMax: 30,
            degradePerHour: 3,
            energyMin: 60,
            energyMax: 100,
            stabilityMin: 20,
            stabilityMax: 70,
            creaturesMin: 0,
            creaturesMax: 2,
            actionMultiplierPct: 100,
            powerYieldPerHour: 4,
            surveyPrecise: true
        });
    }
}
