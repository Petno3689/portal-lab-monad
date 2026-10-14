// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {GameConfig} from "../src/GameConfig.sol";
import {Config, PortalType, PortalTypeParams} from "../src/PortalLabTypes.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @notice Verifies that the canonical deployment configuration passes all
/// constructor guards and is stored verbatim. A constructor revert here means
/// we would get a failed deploy transaction on testnet — better to catch it
/// in CI than after sending a broadcast.
contract DeployConfigTest is Test {
    PortalLab internal lab;

    function setUp() public {
        // Deploy as the script would — config and params verbatim. The random
        // source is stubbed (the real Pyth adapter needs a live Entropy contract
        // this environment has no access to); it does not affect the config guards.
        lab = new PortalLab(GameConfig.config(), GameConfig.portalTypeParams(), new DeterministicSource(0));
    }

    // 1. Constructor accepts GameConfig values without reverting.
    function test_DeploySucceeds() public view {
        assertTrue(address(lab) != address(0));
    }

    // 2. config() round-trips every field exactly as GameConfig specifies.
    function test_ConfigRoundTrip() public view {
        Config memory expected = GameConfig.config();
        Config memory actual = lab.config();

        assertEq(actual.secPerHour, expected.secPerHour, "secPerHour");
        assertEq(actual.longAbsenceHours, expected.longAbsenceHours, "longAbsenceHours");
        assertEq(actual.hpMax, expected.hpMax, "hpMax");
        assertEq(actual.hpStart, expected.hpStart, "hpStart");
        assertEq(actual.hpCollapseBase, expected.hpCollapseBase, "hpCollapseBase");
        assertEq(actual.hpCollapsePerDeath, expected.hpCollapsePerDeath, "hpCollapsePerDeath");
        assertEq(actual.hpEmptyCollapse, expected.hpEmptyCollapse, "hpEmptyCollapse");
        assertEq(actual.hpOverflowPerHour, expected.hpOverflowPerHour, "hpOverflowPerHour");
        assertEq(actual.healPerCreature, expected.healPerCreature, "healPerCreature");
        assertEq(actual.powerMax, expected.powerMax, "powerMax");
        assertEq(actual.powerRegenPerHour, expected.powerRegenPerHour, "powerRegenPerHour");
        assertEq(actual.costToggleQuestioned, expected.costToggleQuestioned, "costToggleQuestioned");
        assertEq(actual.costStabilize, expected.costStabilize, "costStabilize");
        assertEq(actual.costDestabilize, expected.costDestabilize, "costDestabilize");
        assertEq(actual.costSendObserver, expected.costSendObserver, "costSendObserver");
        assertEq(actual.costRecallObserver, expected.costRecallObserver, "costRecallObserver");
        assertEq(actual.costSendRescuer, expected.costSendRescuer, "costSendRescuer");
        assertEq(actual.costRecallRescuer, expected.costRecallRescuer, "costRecallRescuer");
        assertEq(actual.costEvacuate, expected.costEvacuate, "costEvacuate");
        assertEq(actual.costClose, expected.costClose, "costClose");
        assertEq(actual.observersTotal, expected.observersTotal, "observersTotal");
        assertEq(actual.rescuersTotal, expected.rescuersTotal, "rescuersTotal");
        assertEq(actual.rescuerCooldownHours, expected.rescuerCooldownHours, "rescuerCooldownHours");
        assertEq(actual.closeStabilityBelow, expected.closeStabilityBelow, "closeStabilityBelow");
        assertEq(actual.closeHoursAtMost, expected.closeHoursAtMost, "closeHoursAtMost");
        assertEq(actual.basePressurePerHour, expected.basePressurePerHour, "basePressurePerHour");
        assertEq(actual.pressureRampPerHour, expected.pressureRampPerHour, "pressureRampPerHour");
        assertEq(actual.spawnCostUnits, expected.spawnCostUnits, "spawnCostUnits");
        assertEq(actual.closePressureBonus, expected.closePressureBonus, "closePressureBonus");
        assertEq(actual.rangeWidenPerHour, expected.rangeWidenPerHour, "rangeWidenPerHour");
        assertEq(actual.epochHours, expected.epochHours, "epochHours");
        assertEq(actual.requestTimeoutHours, expected.requestTimeoutHours, "requestTimeoutHours");
    }

    // 3. Per-type parameters are stored verbatim for all five portal types.
    function test_PortalTypeParamsRoundTrip() public view {
        PortalTypeParams[5] memory expected = GameConfig.portalTypeParams();

        for (uint8 i = 0; i < 5; i++) {
            PortalTypeParams memory e = expected[i];
            PortalTypeParams memory a = lab.portalTypeParams(PortalType(i));

            assertEq(a.hoursMin, e.hoursMin, "hoursMin");
            assertEq(a.hoursMax, e.hoursMax, "hoursMax");
            assertEq(a.degradePerHour, e.degradePerHour, "degradePerHour");
            assertEq(a.energyMin, e.energyMin, "energyMin");
            assertEq(a.energyMax, e.energyMax, "energyMax");
            assertEq(a.stabilityMin, e.stabilityMin, "stabilityMin");
            assertEq(a.stabilityMax, e.stabilityMax, "stabilityMax");
            assertEq(a.creaturesMin, e.creaturesMin, "creaturesMin");
            assertEq(a.creaturesMax, e.creaturesMax, "creaturesMax");
            assertEq(a.actionMultiplierPct, e.actionMultiplierPct, "actionMultiplierPct");
            assertEq(a.powerYieldPerHour, e.powerYieldPerHour, "powerYieldPerHour");
            assertEq(a.surveyPrecise, e.surveyPrecise, "surveyPrecise");
        }
    }
}
