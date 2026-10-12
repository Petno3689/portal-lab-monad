// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RulesLib} from "../src/RulesLib.sol";
import {Game, Portal, Config, PortalStatus, Action, Refusal, MAX_OPEN_PORTALS} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title RulesLibTest — twelve groups covering action feasibility checks.
contract RulesLibTest is Test {
    PortalLabHarness internal harness;

    function setUp() public {
        harness = new PortalLabHarness();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Active game: started, not finished, full crew, power = 100.
    function _defaultGame() internal pure returns (Game memory g) {
        g.startedAt = 1000;
        g.finished = false;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.power = 100;
    }

    /// @dev Open, surveyed portal: stability 50, energy 50, 24 h, 2 creatures.
    /// Nobody inside; risk score ≈ 50 (Medium) — well clear of Critical.
    function _defaultPortal() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true; // invariant: a surveyed portal has an exact count
        p.stability = 50;
        p.energy = 50;
        p.hoursToCollapse = 24;
        p.creatures = 2;
    }

    function _check(Game memory g, Portal memory p, Action a) internal pure returns (Refusal) {
        return RulesLib.check(g, p, DefaultConfig.config(), 0, a);
    }

    // ── Group 1: Positive case for each action ────────────────────────────────

    function test_Positive_ToggleQuestioned() public pure {
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.ToggleQuestioned)), uint8(Refusal.None));
    }

    function test_Positive_Stabilize() public pure {
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.Stabilize)), uint8(Refusal.None));
    }

    function test_Positive_Destabilize() public pure {
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.Destabilize)), uint8(Refusal.None));
    }

    function test_Positive_SendObserver() public pure {
        // score(50,50,24,0) = 50 (Medium); no observer inside.
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.SendObserver)), uint8(Refusal.None));
    }

    function test_Positive_RecallObserver() public pure {
        Portal memory p = _defaultPortal();
        p.observerInside = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.RecallObserver)), uint8(Refusal.None));
    }

    function test_Positive_SendRescuer() public pure {
        // Default portal: surveyed, creatures=2, no rescuer inside, Medium risk.
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.SendRescuer)), uint8(Refusal.None));
    }

    function test_Positive_RecallRescuer() public pure {
        Portal memory p = _defaultPortal();
        p.rescuerInside = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.RecallRescuer)), uint8(Refusal.None));
    }

    function test_Positive_Evacuate() public pure {
        Portal memory p = _defaultPortal();
        p.rescuerInside = true; // rescuer must be inside to evacuate
        assertEq(uint8(_check(_defaultGame(), p, Action.Evacuate)), uint8(Refusal.None));
    }

    function test_Positive_Close() public pure {
        Portal memory p = _defaultPortal();
        p.hoursToCollapse = 5; // 5 <= closeHoursAtMost(6) => allowed
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.None));
    }

    // ── Group 2: Every row of the state-check table ───────────────────────────

    function test_State_Stabilize_NotSurveyed() public pure {
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        assertEq(uint8(_check(_defaultGame(), p, Action.Stabilize)), uint8(Refusal.NotSurveyed));
    }

    function test_State_Destabilize_NotSurveyed() public pure {
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        assertEq(uint8(_check(_defaultGame(), p, Action.Destabilize)), uint8(Refusal.NotSurveyed));
    }

    function test_State_SendObserver_ObserverAlreadyInside() public pure {
        Portal memory p = _defaultPortal();
        p.observerInside = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendObserver)), uint8(Refusal.ObserverAlreadyInside));
    }

    function test_State_SendObserver_RiskTooHigh() public pure {
        Portal memory p = _defaultPortal();
        // score(20,43,2,0) = 85 (Critical) with 0 creatures and nobody inside.
        p.stability = 20;
        p.energy = 43;
        p.hoursToCollapse = 2;
        p.creatures = 0;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendObserver)), uint8(Refusal.RiskTooHigh));
    }

    function test_State_RecallObserver_NoObserverInside() public pure {
        // observerInside = false (default portal).
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.RecallObserver)), uint8(Refusal.NoObserverInside));
    }

    function test_State_RecallObserver_SurveyPending() public pure {
        Portal memory p = _defaultPortal();
        p.observerInside = true;
        p.surveyPending = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.RecallObserver)), uint8(Refusal.SurveyPending));
    }

    function test_State_SendRescuer_Unsurveyed_Allowed() public pure {
        // Ticket 2.2: a rescuer MAY be sent into an unsurveyed portal (no
        // NotSurveyed gate). The count is unknown (creaturesKnown = false), so the
        // NoCreatures gate is skipped, and the cautious worst-corner risk here is
        // benign (high stabilityLo, low energyHi).
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.stabilityLo = 95;
        p.stabilityHi = 100;
        p.energyLo = 0;
        p.energyHi = 5;
        p.creaturesLo = 2;
        p.creaturesHi = 3;
        p.hoursToCollapse = 48;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.None));
    }

    function test_State_SendRescuer_RescuerAlreadyInside() public pure {
        Portal memory p = _defaultPortal();
        p.rescuerInside = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.RescuerAlreadyInside));
    }

    function test_State_SendRescuer_NoCreatures() public pure {
        Portal memory p = _defaultPortal();
        p.creatures = 0;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.NoCreatures));
    }

    function test_State_SendRescuer_RiskTooHigh() public pure {
        Portal memory p = _defaultPortal();
        // score(20,69,6,2) with 2 creatures = Critical; confirmed by the 1.2 gate test.
        // We use creatures=2 (default) so lives=2 when neither inside.
        // score(20,69,6,2): step4 base; step5 h=6<=6; step7 lives=2 k=min(30,16)=16.
        // Exact score not derived here — the library computes it. Just verify the gate.
        p.stability = 20;
        p.energy = 75; // high energy ensures Critical even with small lives
        p.hoursToCollapse = 6;
        // creatures = 2 (default), observerInside=false, rescuerInside=false => lives=2
        // score(20,75,6,2) expected ≥ 85 (Critical); mutation vector 20/75/8/2 gives 83,
        // so use hoursToCollapse=2 to be safely in Critical territory.
        p.hoursToCollapse = 2;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.RiskTooHigh));
    }

    function test_State_RecallRescuer_NoRescuerInside() public pure {
        // rescuerInside = false (default portal).
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.RecallRescuer)), uint8(Refusal.NoRescuerInside));
    }

    function test_State_Evacuate_Unsurveyed_Allowed() public pure {
        // Ticket 2.2: a blind-entered portal (unsurveyed but count known, rescuer
        // inside) may be evacuated — no NotSurveyed gate. The blind evacuation
        // leaving one behind is EffectsLib's concern; here we only assert the rule
        // permits it.
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        p.creaturesKnown = true; // a prior blind entry made the count known
        p.creatures = 2;
        p.rescuerInside = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.Evacuate)), uint8(Refusal.None));
    }

    function test_State_Evacuate_NoCreatures() public pure {
        Portal memory p = _defaultPortal();
        p.creatures = 0;
        assertEq(uint8(_check(_defaultGame(), p, Action.Evacuate)), uint8(Refusal.NoCreatures));
    }

    function test_State_Evacuate_NoRescuerInside() public pure {
        // Default portal: surveyed, creatures=2, rescuerInside=false.
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.Evacuate)), uint8(Refusal.NoRescuerInside));
    }

    function test_State_Close_NotUnstableEnough() public pure {
        // Default portal: stability=50 >= closeStabilityBelow(40), hoursToCollapse=24 > closeHoursAtMost(6).
        assertEq(uint8(_check(_defaultGame(), _defaultPortal(), Action.Close)), uint8(Refusal.NotUnstableEnough));
    }

    // ── Group 3: Common checks ────────────────────────────────────────────────

    function test_Common_GameNotActive_NoGame() public pure {
        Game memory g; // startedAt = 0
        assertEq(uint8(RulesLib.check(g, _defaultPortal(), DefaultConfig.config(), 0, Action.Stabilize)), uint8(Refusal.GameNotActive));
    }

    function test_Common_GameNotActive_Finished() public pure {
        Game memory g = _defaultGame();
        g.finished = true;
        assertEq(uint8(RulesLib.check(g, _defaultPortal(), DefaultConfig.config(), 0, Action.Stabilize)), uint8(Refusal.GameNotActive));
    }

    function test_Common_InvalidSlot() public pure {
        assertEq(uint8(RulesLib.check(_defaultGame(), _defaultPortal(), DefaultConfig.config(), 12, Action.Stabilize)), uint8(Refusal.InvalidSlot));
    }

    function test_Common_PortalEmpty() public pure {
        Portal memory p; // status = Empty (default)
        assertEq(uint8(RulesLib.check(_defaultGame(), p, DefaultConfig.config(), 0, Action.Stabilize)), uint8(Refusal.PortalEmpty));
    }

    // ── Group 4: Closing threshold ────────────────────────────────────────────

    // DefaultConfig: closeStabilityBelow = 40, closeHoursAtMost = 6.

    function test_Close_Surveyed_StabilityUnder40_Allowed() public pure {
        Portal memory p = _defaultPortal();
        p.stability = 39; // 39 < 40 => allowed
        p.hoursToCollapse = 24;
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.None));
    }

    function test_Close_Surveyed_Stability40_Hours24_Refused() public pure {
        Portal memory p = _defaultPortal();
        p.stability = 40; // 40 >= 40; 24 > 6 => refused
        p.hoursToCollapse = 24;
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.NotUnstableEnough));
    }

    function test_Close_Surveyed_Stability40_Hours6_Allowed() public pure {
        Portal memory p = _defaultPortal();
        p.stability = 40; // 40 >= 40 but 6 <= 6 => allowed
        p.hoursToCollapse = 6;
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.None));
    }

    function test_Close_Surveyed_Stability40_Hours7_Refused() public pure {
        Portal memory p = _defaultPortal();
        p.stability = 40; // 40 >= 40; 7 > 6 => refused
        p.hoursToCollapse = 7;
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.NotUnstableEnough));
    }

    function test_Close_Unsurveyed_Hours7_Refused() public pure {
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        p.stability = 0; // stability field is 0 but must NOT be used for unsurveyed
        p.hoursToCollapse = 7; // 7 > 6 => refused regardless of stability field
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.NotUnstableEnough));
    }

    function test_Close_Unsurveyed_Hours6_Allowed() public pure {
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        p.hoursToCollapse = 6; // 6 <= 6 => allowed even without survey
        assertEq(uint8(_check(_defaultGame(), p, Action.Close)), uint8(Refusal.None));
    }

    // ── Group 5: Risk as gate ─────────────────────────────────────────────────

    function test_Risk_SendObserver_Critical_Refused() public pure {
        Portal memory p = _defaultPortal();
        // score(20,43,2,0) = 85 (Critical) — from test 1.2 gate vectors.
        p.stability = 20;
        p.energy = 43;
        p.hoursToCollapse = 2;
        p.creatures = 0;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendObserver)), uint8(Refusal.RiskTooHigh));
    }

    function test_Risk_SendObserver_High_Allowed() public pure {
        Portal memory p = _defaultPortal();
        // score(20,37,2,0) = 84 (High) — from test 1.2 gate vectors.
        p.stability = 20;
        p.energy = 37;
        p.hoursToCollapse = 2;
        p.creatures = 0;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendObserver)), uint8(Refusal.None));
    }

    function test_Risk_SendRescuer_Critical_Refused() public pure {
        Portal memory p = _defaultPortal();
        // score(20,69,6,1) = 85 (Critical) — from test 1.2 gate vectors.
        // creatures=1, observerInside=false, rescuerInside=false => lives=1.
        p.stability = 20;
        p.energy = 69;
        p.hoursToCollapse = 6;
        p.creatures = 1;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.RiskTooHigh));
    }

    function test_Risk_SendRescuer_High_Allowed() public pure {
        Portal memory p = _defaultPortal();
        // score(20,64,6,1) = 84 (High) — from test 1.2 gate vectors.
        p.stability = 20;
        p.energy = 64;
        p.hoursToCollapse = 6;
        p.creatures = 1;
        assertEq(uint8(_check(_defaultGame(), p, Action.SendRescuer)), uint8(Refusal.None));
    }

    // ── Group 6: Unsurveyed portal + SendObserver skips risk ──────────────────

    function test_SendObserver_Unsurveyed_SkipsRiskCheck() public pure {
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        // Worst possible values in the fields — risk would be Critical if evaluated.
        p.stability = 0;
        p.energy = 100;
        p.hoursToCollapse = 0;
        p.creatures = 5;
        // Should still be None: sending an observer IS the survey; risk is unknown.
        assertEq(uint8(_check(_defaultGame(), p, Action.SendObserver)), uint8(Refusal.None));
    }

    // ── Group 7: Recall observer during survey ────────────────────────────────

    function test_RecallObserver_SurveyPending_Refused() public pure {
        Portal memory p = _defaultPortal();
        p.observerInside = true;
        p.surveyPending = true;
        assertEq(uint8(_check(_defaultGame(), p, Action.RecallObserver)), uint8(Refusal.SurveyPending));
    }

    // ── Group 8: Crew availability ────────────────────────────────────────────

    function test_Crew_NoObserverFree() public pure {
        Game memory g = _defaultGame();
        g.observersFree = 0;
        assertEq(uint8(_check(g, _defaultPortal(), Action.SendObserver)), uint8(Refusal.NoObserverFree));
    }

    function test_Crew_NoRescuerFree() public pure {
        Game memory g = _defaultGame();
        g.rescuersFree = 0;
        // Default portal: surveyed, creatures=2, no rescuer inside, Medium risk.
        assertEq(uint8(_check(g, _defaultPortal(), Action.SendRescuer)), uint8(Refusal.NoRescuerFree));
    }

    // ── Group 9: Power cost for each action ───────────────────────────────────

    function test_Power_ToggleQuestioned_ZeroCost_Allowed() public pure {
        Game memory g = _defaultGame();
        g.power = 0;
        assertEq(uint8(_check(g, _defaultPortal(), Action.ToggleQuestioned)), uint8(Refusal.None));
    }

    function test_Power_Stabilize() public pure {
        Config memory c = DefaultConfig.config(); // costStabilize = 5
        Portal memory p = _defaultPortal();
        Game memory g = _defaultGame();
        g.power = c.costStabilize - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Stabilize)), uint8(Refusal.NotEnoughPower));
        g.power = c.costStabilize;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Stabilize)), uint8(Refusal.None));
    }

    function test_Power_Destabilize() public pure {
        Config memory c = DefaultConfig.config(); // costDestabilize = 5
        Portal memory p = _defaultPortal();
        Game memory g = _defaultGame();
        g.power = c.costDestabilize - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Destabilize)), uint8(Refusal.NotEnoughPower));
        g.power = c.costDestabilize;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Destabilize)), uint8(Refusal.None));
    }

    function test_Power_SendObserver() public pure {
        Config memory c = DefaultConfig.config(); // costSendObserver = 10
        Portal memory p = _defaultPortal();
        Game memory g = _defaultGame();
        g.power = c.costSendObserver - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.SendObserver)), uint8(Refusal.NotEnoughPower));
        g.power = c.costSendObserver;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.SendObserver)), uint8(Refusal.None));
    }

    function test_Power_RecallObserver() public pure {
        Config memory c = DefaultConfig.config(); // costRecallObserver = 5
        Portal memory p = _defaultPortal();
        p.observerInside = true;
        Game memory g = _defaultGame();
        g.power = c.costRecallObserver - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.RecallObserver)), uint8(Refusal.NotEnoughPower));
        g.power = c.costRecallObserver;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.RecallObserver)), uint8(Refusal.None));
    }

    function test_Power_SendRescuer() public pure {
        Config memory c = DefaultConfig.config(); // costSendRescuer = 20
        Portal memory p = _defaultPortal(); // creatures=2, not Critical
        Game memory g = _defaultGame();
        g.power = c.costSendRescuer - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.SendRescuer)), uint8(Refusal.NotEnoughPower));
        g.power = c.costSendRescuer;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.SendRescuer)), uint8(Refusal.None));
    }

    function test_Power_RecallRescuer() public pure {
        Config memory c = DefaultConfig.config(); // costRecallRescuer = 10
        Portal memory p = _defaultPortal();
        p.rescuerInside = true;
        Game memory g = _defaultGame();
        g.power = c.costRecallRescuer - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.RecallRescuer)), uint8(Refusal.NotEnoughPower));
        g.power = c.costRecallRescuer;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.RecallRescuer)), uint8(Refusal.None));
    }

    function test_Power_Evacuate() public pure {
        Config memory c = DefaultConfig.config(); // costEvacuate = 10
        Portal memory p = _defaultPortal();
        p.rescuerInside = true;
        Game memory g = _defaultGame();
        g.power = c.costEvacuate - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Evacuate)), uint8(Refusal.NotEnoughPower));
        g.power = c.costEvacuate;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Evacuate)), uint8(Refusal.None));
    }

    function test_Power_Close() public pure {
        Config memory c = DefaultConfig.config(); // costClose = 25
        Portal memory p = _defaultPortal();
        p.hoursToCollapse = 5; // passes threshold
        Game memory g = _defaultGame();
        g.power = c.costClose - 1;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Close)), uint8(Refusal.NotEnoughPower));
        g.power = c.costClose;
        assertEq(uint8(RulesLib.check(g, p, c, 0, Action.Close)), uint8(Refusal.None));
    }

    // ── Group 10: Check priority ordering ────────────────────────────────────

    function test_Priority_NotSurveyed_BeforeNotEnoughPower() public pure {
        // Stabilize: not surveyed AND power = 0. Must return NotSurveyed, not NotEnoughPower.
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        Game memory g = _defaultGame();
        g.power = 0;
        assertEq(uint8(_check(g, p, Action.Stabilize)), uint8(Refusal.NotSurveyed));
    }

    function test_Priority_GameNotActive_BeforePortalEmpty() public pure {
        // Finished game AND empty portal slot. Must return GameNotActive first.
        Game memory g = _defaultGame();
        g.finished = true;
        Portal memory empty;
        assertEq(uint8(RulesLib.check(g, empty, DefaultConfig.config(), 0, Action.Stabilize)), uint8(Refusal.GameNotActive));
    }

    function test_Priority_NoRescuerFree_BeforeNotEnoughPower() public pure {
        // SendRescuer: no rescuers free AND not enough power. Must return NoRescuerFree.
        Portal memory p = _defaultPortal(); // surveyed, creatures=2, no rescuer inside
        Game memory g = _defaultGame();
        g.rescuersFree = 0;
        g.power = 0;
        assertEq(uint8(_check(g, p, Action.SendRescuer)), uint8(Refusal.NoRescuerFree));
    }

    // ── Group 11: All 15 non-None refusal codes are reachable ─────────────────

    function test_AllFifteenRefusalsReachable() public pure {
        bool[16] memory seen;
        Config memory c = DefaultConfig.config();
        Game memory g = _defaultGame();
        Portal memory p = _defaultPortal();

        // GameNotActive
        { Game memory g0; seen[uint8(RulesLib.check(g0, p, c, 0, Action.Stabilize))] = true; }
        // InvalidSlot
        seen[uint8(RulesLib.check(g, p, c, 12, Action.Stabilize))] = true;
        // PortalEmpty
        { Portal memory empty; seen[uint8(RulesLib.check(g, empty, c, 0, Action.Stabilize))] = true; }
        // NotSurveyed
        { Portal memory pNS = _defaultPortal(); pNS.surveyed = false;
          seen[uint8(RulesLib.check(g, pNS, c, 0, Action.Stabilize))] = true; }
        // SurveyPending
        { Portal memory pSP = _defaultPortal(); pSP.observerInside = true; pSP.surveyPending = true;
          seen[uint8(RulesLib.check(g, pSP, c, 0, Action.RecallObserver))] = true; }
        // ObserverAlreadyInside
        { Portal memory pOA = _defaultPortal(); pOA.observerInside = true;
          seen[uint8(RulesLib.check(g, pOA, c, 0, Action.SendObserver))] = true; }
        // NoObserverInside (RecallObserver on portal without observer)
        seen[uint8(RulesLib.check(g, p, c, 0, Action.RecallObserver))] = true;
        // NoObserverFree
        { Game memory gNO = _defaultGame(); gNO.observersFree = 0;
          seen[uint8(RulesLib.check(gNO, p, c, 0, Action.SendObserver))] = true; }
        // RescuerAlreadyInside
        { Portal memory pRA = _defaultPortal(); pRA.rescuerInside = true;
          seen[uint8(RulesLib.check(g, pRA, c, 0, Action.SendRescuer))] = true; }
        // NoRescuerInside (Evacuate: surveyed, creatures=2, rescuerInside=false)
        seen[uint8(RulesLib.check(g, p, c, 0, Action.Evacuate))] = true;
        // NoRescuerFree
        { Game memory gNR = _defaultGame(); gNR.rescuersFree = 0;
          seen[uint8(RulesLib.check(gNR, p, c, 0, Action.SendRescuer))] = true; }
        // NoCreatures
        { Portal memory pNC = _defaultPortal(); pNC.creatures = 0;
          seen[uint8(RulesLib.check(g, pNC, c, 0, Action.SendRescuer))] = true; }
        // RiskTooHigh (SendObserver, score(20,43,2,0) = 85 Critical)
        { Portal memory pRT = _defaultPortal(); pRT.stability = 20; pRT.energy = 43; pRT.hoursToCollapse = 2; pRT.creatures = 0;
          seen[uint8(RulesLib.check(g, pRT, c, 0, Action.SendObserver))] = true; }
        // NotUnstableEnough (Close, default portal: stability=50, hours=24)
        seen[uint8(RulesLib.check(g, p, c, 0, Action.Close))] = true;
        // NotEnoughPower
        { Game memory gNEP = _defaultGame(); gNEP.power = 0;
          seen[uint8(RulesLib.check(gNEP, p, c, 0, Action.Stabilize))] = true; }

        uint256 count;
        for (uint256 i = 1; i < 16; i++) {
            if (seen[i]) count++;
        }
        assertEq(count, 15, "not all 15 refusal codes were reached");
    }

    // ── Group 12: canAct via PortalLabHarness ─────────────────────────────────

    function test_CanAct_Harness_BasicPositive() public {
        Game memory g = _defaultGame();
        Portal memory p = _defaultPortal();
        harness.setGame(address(this), g);
        harness.setPortal(address(this), 0, p);
        assertEq(uint8(harness.canAct(address(this), 0, Action.Stabilize)), uint8(Refusal.None));
    }

    function test_CanAct_Harness_NotSurveyed() public {
        Game memory g = _defaultGame();
        Portal memory p = _defaultPortal();
        p.surveyed = false;
        harness.setGame(address(this), g);
        harness.setPortal(address(this), 0, p);
        assertEq(uint8(harness.canAct(address(this), 0, Action.Stabilize)), uint8(Refusal.NotSurveyed));
    }

    function test_CanAct_Harness_PortalEmpty() public {
        Game memory g = _defaultGame();
        // No portal set — slot 0 defaults to Empty.
        harness.setGame(address(this), g);
        assertEq(uint8(harness.canAct(address(this), 0, Action.Stabilize)), uint8(Refusal.PortalEmpty));
    }

    function test_CanAct_Harness_NoCreatures() public {
        Game memory g = _defaultGame();
        Portal memory p = _defaultPortal();
        p.creatures = 0;
        harness.setGame(address(this), g);
        harness.setPortal(address(this), 0, p);
        assertEq(uint8(harness.canAct(address(this), 0, Action.SendRescuer)), uint8(Refusal.NoCreatures));
    }

    function test_CanAct_Harness_Close_Allowed() public {
        Game memory g = _defaultGame();
        Portal memory p = _defaultPortal();
        p.hoursToCollapse = 5; // passes threshold
        harness.setGame(address(this), g);
        harness.setPortal(address(this), 0, p);
        assertEq(uint8(harness.canAct(address(this), 0, Action.Close)), uint8(Refusal.None));
    }

    function test_CanAct_Harness_InvalidSlot() public {
        Game memory g = _defaultGame();
        harness.setGame(address(this), g);
        assertEq(uint8(harness.canAct(address(this), 12, Action.Stabilize)), uint8(Refusal.InvalidSlot));
    }

    function test_CanAct_Harness_NoGame_GameNotActive() public view {
        // Player address with no game written — startedAt defaults to 0.
        assertEq(uint8(harness.canAct(address(0xdead), 0, Action.Stabilize)), uint8(Refusal.GameNotActive));
    }
}
