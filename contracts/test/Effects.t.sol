// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Portal, PortalType, PortalStatus, Action, Refusal} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title EffectsTest — twelve groups covering `act` and `EffectsLib`.
/// @notice State is prepared through `PortalLabHarness` (setGame / setPortal)
/// and driven through `harness.act`, so each test exercises the full flow:
/// feasibility, cost, effect, storage and events. Structs are built fresh by
/// helpers (never assigned by copy — CLAUDE.md rule), so cases cannot alias.
contract EffectsTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(this);
        // All timestamps below sit at BASE, so time-catch-up in `act` (ticket
        // 1.6) is a no-op and these action tests keep their 1.5 semantics.
        vm.warp(BASE);
    }

    uint40 internal constant BASE = 1000;

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Active game: started, not finished, full crew, power 100, hp 100,
    /// one open portal.
    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE; // == now in setUp, so catch-up ages nothing
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    /// @dev Open, surveyed portal: stability 50, energy 50, 24 h, 2 creatures.
    function _portal() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true; // surveyed => creatures count is exact
        p.stability = 50;
        p.energy = 50;
        p.hoursToCollapse = 24;
        p.creatures = 2;
        p.snapshotAt = BASE; // == now in setUp, so ageing is a no-op
    }

    function _write(Game memory g, Portal memory p) internal {
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);
    }

    function _game_() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _portal_(uint8 slot) internal view returns (Portal memory) {
        return harness.getPortals(player)[slot];
    }

    // ── Group 1: Each of the nine actions changes state per the table ─────────

    function test_ToggleQuestioned() public {
        Portal memory p = _portal(); // status Open
        _write(_game(), p);
        harness.act(0, Action.ToggleQuestioned);
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Questioned));

        // Toggling again returns to Open.
        harness.act(0, Action.ToggleQuestioned);
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Open));
    }

    function test_Stabilize() public {
        _write(_game(), _portal()); // stability 50, energy 50
        harness.act(0, Action.Stabilize);
        Portal memory p = _portal_(0);
        assertEq(p.stability, 75); // 50 + 25
        assertEq(p.energy, 40); // 50 - 10
        assertEq(_game_().power, 95); // 100 - 5
    }

    function test_Destabilize() public {
        _write(_game(), _portal());
        harness.act(0, Action.Destabilize);
        Portal memory p = _portal_(0);
        assertEq(p.stability, 25); // 50 - 25
        assertEq(p.energy, 60); // 50 + 10
        assertEq(_game_().power, 95); // 100 - 5
    }

    function test_SendObserver_Unsurveyed_SurveysTwoPhase() public {
        // Sending an observer into an unsurveyed portal is two-phase (SPEC §6.3):
        // `act` commits (observer in, power spent, surveyPending = true, word
        // requested) and `reveal` completes it. After both, the portal is surveyed
        // and surveyPending is cleared. `_portal()` has zero ranges, so a precise
        // survey collapses every field to 0; survey mechanics are in Survey.t.sol.
        Portal memory p = _portal();
        p.surveyed = false;
        _write(_game(), p);

        harness.act(0, Action.SendObserver); // commit
        // After commit, before reveal: observer in, survey pending, power spent.
        Portal memory mid = _portal_(0);
        assertTrue(mid.observerInside);
        assertFalse(mid.surveyed);
        assertTrue(mid.surveyPending);
        assertEq(_game_().observersFree, 2); // 3 - 1
        assertEq(_game_().power, 90); // 100 - 10

        harness.reveal(player); // reveal
        Portal memory after_ = _portal_(0);
        assertTrue(after_.observerInside);
        assertTrue(after_.surveyed); // surveyed on reveal
        assertFalse(after_.surveyPending); // cleared on reveal
        assertEq(_game_().observersFree, 2); // unchanged by reveal
        assertEq(_game_().power, 90); // unchanged by reveal
    }

    function test_SendObserver_Surveyed_NoPending() public {
        _write(_game(), _portal()); // surveyed
        harness.act(0, Action.SendObserver);
        Portal memory after_ = _portal_(0);
        assertTrue(after_.observerInside);
        assertFalse(after_.surveyPending);
        assertEq(_game_().observersFree, 2);
    }

    function test_RecallObserver() public {
        Portal memory p = _portal();
        p.observerInside = true;
        Game memory g = _game();
        g.observersFree = 2; // one currently inside
        _write(g, p);
        harness.act(0, Action.RecallObserver);
        assertFalse(_portal_(0).observerInside);
        assertEq(_game_().observersFree, 3); // 2 + 1
        assertEq(_game_().power, 95); // 100 - 5
    }

    function test_SendRescuer() public {
        Portal memory p = _portal(); // surveyed, creatures 2
        _write(_game(), p);
        harness.act(0, Action.SendRescuer);
        assertTrue(_portal_(0).rescuerInside);
        assertEq(_game_().rescuersFree, 1); // 2 - 1
        assertEq(_game_().power, 80); // 100 - 20
    }

    function test_RecallRescuer() public {
        Portal memory p = _portal();
        p.rescuerInside = true;
        Game memory g = _game();
        g.rescuersFree = 1;
        _write(g, p);
        harness.act(0, Action.RecallRescuer);
        assertFalse(_portal_(0).rescuerInside);
        assertEq(_game_().rescuersFree, 2); // 1 + 1
        assertEq(_game_().power, 90); // 100 - 10
    }

    function test_Evacuate() public {
        Portal memory p = _portal(); // creatures 2
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);
        harness.act(0, Action.Evacuate);
        Portal memory after_ = _portal_(0);
        assertEq(after_.creatures, 0);
        assertFalse(after_.rescuerInside);
        assertEq(_game_().rescuersFree, 2); // 1 + 1
        assertEq(_game_().hp, 56); // 50 + 2 * 3
        assertEq(_game_().power, 90); // 100 - 10
    }

    function test_Close_Basic() public {
        Portal memory p = _portal();
        p.creatures = 0; // empty, surveyed
        p.hoursToCollapse = 5; // <= closeHoursAtMost (6)
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Empty));
        assertEq(_game_().openPortals, 0);
        assertEq(_game_().power, 75); // 100 - 25
    }

    // ── Group 2: Ceilings and floors ─────────────────────────────────────────

    function test_Stabilize_ClampsHigh() public {
        Portal memory p = _portal();
        p.stability = 90;
        p.energy = 5;
        _write(_game(), p);
        harness.act(0, Action.Stabilize);
        Portal memory after_ = _portal_(0);
        assertEq(after_.stability, 100); // 90 + 25 -> capped, not 115
        assertEq(after_.energy, 0); // 5 - 10 -> floored, not negative
    }

    function test_Destabilize_ClampsLow() public {
        Portal memory p = _portal();
        p.stability = 10;
        p.energy = 95;
        _write(_game(), p);
        harness.act(0, Action.Destabilize);
        Portal memory after_ = _portal_(0);
        assertEq(after_.stability, 0); // 10 - 25 -> floored
        assertEq(after_.energy, 100); // 95 + 10 -> capped
    }

    // ── Group 3: Resonant portal — double action strength ────────────────────

    function test_Resonant_Stabilize() public {
        Portal memory p = _portal();
        p.portalType = PortalType.Resonant; // actionMultiplierPct = 200
        p.stability = 20;
        _write(_game(), p);
        harness.act(0, Action.Stabilize);
        assertEq(_portal_(0).stability, 70); // 20 + 50
    }

    function test_Resonant_Destabilize() public {
        Portal memory p = _portal();
        p.portalType = PortalType.Resonant;
        p.stability = 60;
        _write(_game(), p);
        harness.act(0, Action.Destabilize);
        assertEq(_portal_(0).stability, 10); // 60 - 50
    }

    // ── Group 4: Resource is deducted by exactly the cost ────────────────────

    function test_PowerDeducted_Stabilize() public {
        Game memory g = _game();
        g.power = 42;
        _write(g, _portal());
        harness.act(0, Action.Stabilize);
        assertEq(_game_().power, 37); // 42 - 5
    }

    function test_PowerDeducted_SendRescuer() public {
        Game memory g = _game();
        g.power = 42;
        _write(g, _portal());
        harness.act(0, Action.SendRescuer);
        assertEq(_game_().power, 22); // 42 - 20
    }

    // ── Group 5: A refusal reverts and rolls everything back ─────────────────

    function test_Refusal_NotSurveyed_RollsBack() public {
        Portal memory p = _portal();
        p.surveyed = false;
        _write(_game(), p);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.ActionRefused.selector, Refusal.NotSurveyed));
        harness.act(0, Action.Stabilize);
        // State unchanged.
        assertEq(_game_().power, 100);
        assertEq(_portal_(0).stability, 50);
        assertEq(_portal_(0).energy, 50);
    }

    function test_Refusal_NoCreatures_RollsBack() public {
        Portal memory p = _portal();
        p.creatures = 0;
        _write(_game(), p);
        vm.expectRevert(abi.encodeWithSelector(PortalLab.ActionRefused.selector, Refusal.NoCreatures));
        harness.act(0, Action.SendRescuer);
        assertEq(_game_().power, 100);
        assertEq(_game_().rescuersFree, 2);
        assertFalse(_portal_(0).rescuerInside);
    }

    function test_Refusal_NotUnstableEnough_RollsBack() public {
        // Default portal: stability 50 >= 40, hoursToCollapse 24 > 6 => refused.
        _write(_game(), _portal());
        vm.expectRevert(abi.encodeWithSelector(PortalLab.ActionRefused.selector, Refusal.NotUnstableEnough));
        harness.act(0, Action.Close);
        assertEq(_game_().power, 100);
        assertEq(_game_().openPortals, 1);
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Open));
    }

    // ── Group 6: Evacuation ──────────────────────────────────────────────────

    function test_Evacuate_TwoCreatures_HealsExact() public {
        Portal memory p = _portal(); // creatures 2
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);
        harness.act(0, Action.Evacuate);
        assertEq(_game_().hp, 56); // 50 + 2 * healPerCreature(3)
        assertEq(_game_().rescuersFree, 2); // rescuer freed
    }

    function test_Evacuate_CapsAtHpMax() public {
        Portal memory p = _portal(); // creatures 2
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 99; // hpMax - 1
        g.rescuersFree = 1;
        _write(g, p);
        harness.act(0, Action.Evacuate);
        assertEq(_game_().hp, 100); // capped at hpMax, not 105
    }

    // ── Group 7: Closing an empty surveyed portal costs no HP ─────────────────

    function test_Close_EmptySurveyed_NoHpLoss() public {
        Portal memory p = _portal();
        p.creatures = 0;
        p.hoursToCollapse = 5; // passes the time threshold
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(_game_().hp, 100); // unchanged
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Empty));
        assertEq(_game_().openPortals, 0);
    }

    // ── Group 8: Closing with beings inside ──────────────────────────────────

    function test_Close_WithLiving_DeathsAndHpLoss() public {
        Portal memory p = _portal(); // surveyed, creatures 2
        p.stability = 30; // < closeStabilityBelow (40) => allowed
        p.observerInside = true;
        p.rescuerInside = true;
        Game memory g = _game();
        g.observersFree = 2; // one inside
        g.rescuersFree = 1; // one inside
        _write(g, p);
        harness.act(0, Action.Close);
        // deaths = 2 creatures + observer + rescuer = 4; hpLost = 8*4 = 32 (no base).
        assertEq(_game_().hp, 68); // 100 - 32
        // Crew inside died: pools NOT incremented.
        assertEq(_game_().observersFree, 2);
        assertEq(_game_().rescuersFree, 1);
        assertEq(_game_().openPortals, 0);
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Empty));
    }

    // ── Group 9: Blind close reads the range, not `creatures` ─────────────────

    // Renamed from test_Close_Blind_UsesRangeMidpoint (ticket 2.2 §4.1): the body
    // has always asserted the UPPER BOUND (creaturesHi), never the midpoint. Body
    // and comments were correct; only the name lied. It is NOT a full duplicate of
    // BalanceRulesTest.test_8_3_BlindClose_ChargesUpperBound — different range
    // (1..4 vs 2..3), different closable gate (by time here, by stability there),
    // and it drives through EffectsTest's harness — so both are kept.
    function test_Close_Blind_ChargesUpperBound() public {
        Portal memory p = _portal();
        p.surveyed = false;
        p.creaturesKnown = false; // explicit: creatures count is unknown
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        p.creatures = 9; // MUST be ignored — creaturesKnown is false
        p.hoursToCollapse = 6; // <= closeHoursAtMost => allowed
        _write(_game(), p);
        harness.act(0, Action.Close);
        // deaths = creaturesHi = 4 (upper bound, creaturesKnown false); hpLost = 8*4 = 32.
        // If `creatures` (9) were read, hpLost would be 72; if midpoint (2.5), hpLost would be 20.
        assertEq(_game_().hp, 68); // 100 - 32
        assertEq(_game_().openPortals, 0);
    }

    // ── Group 10: Death from one's own action ────────────────────────────────

    function test_Close_KillsPlayer() public {
        Portal memory p = _portal();
        p.stability = 30; // allows close
        p.observerInside = true;
        p.rescuerInside = true; // deaths = 2 + 1 + 1 = 4, hpLost = 8*4 = 32
        Game memory g = _game();
        g.hp = 10;
        g.observersFree = 2;
        g.rescuersFree = 1;
        _write(g, p);

        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameOver(player, 0);
        harness.act(0, Action.Close);

        assertEq(_game_().hp, 0); // 10 - 32 -> floored at 0
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 0); // hoursElapsed is 0 until ticket 1.6
    }

    // ── Group 11: Events carry the right fields ──────────────────────────────

    function test_Event_ActionPerformed_Stabilize() public {
        _write(_game(), _portal());
        vm.expectEmit(true, true, false, true);
        emit PortalLab.ActionPerformed(player, 0, Action.Stabilize, 5, 0);
        harness.act(0, Action.Stabilize);
    }

    function test_Event_ActionPerformed_SendObserver() public {
        _write(_game(), _portal());
        vm.expectEmit(true, true, false, true);
        emit PortalLab.ActionPerformed(player, 0, Action.SendObserver, 10, 0);
        harness.act(0, Action.SendObserver);
    }

    function test_Event_CreaturesRescued() public {
        Portal memory p = _portal(); // creatures 2
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.CreaturesRescued(player, 0, 2, 6, 0); // 2 creatures, +6 hp
        harness.act(0, Action.Evacuate);
    }

    function test_Event_PortalClosed() public {
        Portal memory p = _portal();
        p.stability = 30;
        p.observerInside = true;
        p.rescuerInside = true; // deaths 4, hpLost = 8*4 = 32 (no base)
        Game memory g = _game();
        g.observersFree = 2;
        g.rescuersFree = 1;
        _write(g, p);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalClosed(player, 0, 4, 32, 0);
        harness.act(0, Action.Close);
    }

    // ── Group 12: Dead crew does not return to the pool ──────────────────────

    function test_DeadCrew_DoesNotReturn() public {
        // One observer inside slot 0 (observersFree = 2 of 3). Close slot 0: the
        // observer dies. Then send a new observer to slot 1. If the dead one had
        // returned, observersFree would be 2 after the second send; because it
        // did not, it is 1.
        Portal memory p0 = _portal();
        p0.stability = 30; // allows close
        p0.creatures = 0; // only the observer inside dies
        p0.observerInside = true;

        Portal memory p1 = _portal(); // valid target for SendObserver

        Game memory g = _game();
        g.observersFree = 2; // one already inside slot 0
        g.openPortals = 2;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p0);
        harness.setPortal(player, 1, p1);

        harness.act(0, Action.Close); // observer dies, observersFree stays 2
        assertEq(_game_().observersFree, 2);

        harness.act(1, Action.SendObserver); // deploy a new observer
        assertEq(_game_().observersFree, 1); // 2 - 1, dead one never returned
    }
}
