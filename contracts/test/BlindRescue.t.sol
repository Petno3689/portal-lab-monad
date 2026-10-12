// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Config, Game, Portal, PortalType, PortalTypeParams, PortalStatus, Action, Refusal, MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @title BlindRescueTest — ticket 2.2 §5: blind rescue, blind evacuation, the
/// rescuer cooldown, and the cautious risk gate that protects only the rescuer.
/// Updated in Ticket 4.6: blind rescue is now two-phase (commit + reveal).
contract BlindRescueTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15; // DefaultConfig.secPerHour

    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    /// @dev A benign UNSURVEYED portal: worst-corner risk is well clear of Critical.
    function _unsurveyed() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.creaturesKnown = false;
        p.hoursToCollapse = 48; // long life, so ageing does not collapse it in-test
        p.snapshotAt = BASE;
        p.energyLo = 0;
        p.energyHi = 5; // energyHi is the worst corner; keep it low
        p.stabilityLo = 95; // stabilityLo is the worst corner; keep it high
        p.stabilityHi = 100;
        p.creaturesLo = 2;
        p.creaturesHi = 3;
    }

    function _write(Game memory g, Portal memory p) internal {
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);
    }

    function _g() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _p(uint8 slot) internal view returns (Portal memory) {
        return harness.getPortals(player)[slot];
    }

    // ── 5.1: a rescuer may be sent into an unsurveyed portal ──────────────────

    function test_5_1_SendRescuer_Unsurveyed_Allowed() public {
        _write(_game(), _unsurveyed());
        assertEq(uint8(harness.canAct(player, 0, Action.SendRescuer)), uint8(Refusal.None));
        // Commit goes through without revert.
        harness.act(0, Action.SendRescuer);
        assertTrue(harness.getPending(player).active, "deferral active after commit");
        // Reveal completes the flow.
        source.reveal(harness.getPending(player).requestId);
    }

    // ── 5.2: blind entry rolls the count, marks it known, collapses the range ─
    // Updated for Ticket 4.6: now two-phase (commit + reveal).

    function test_5_2_BlindEntry_RollsAndCollapsesRange() public {
        Portal memory p = _unsurveyed();
        p.creaturesLo = 2;
        p.creaturesHi = 3; // roll lands on 2 or 3 (never 0) -> the rescuer enters
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit
        // After commit: rescuer out of pool, pending active, portal flag set.
        assertEq(_g().rescuersFree, 1, "one rescuer committed at commit");
        assertTrue(harness.getPending(player).active, "pending active after commit");
        assertTrue(_p(0).rescuerPending, "rescuerPending set at commit");
        assertFalse(_p(0).creaturesKnown, "count not yet known at commit");

        source.reveal(harness.getPending(player).requestId); // reveal

        Portal memory after_ = _p(0);
        assertTrue(after_.creaturesKnown, "creaturesKnown becomes true on blind entry");
        assertTrue(after_.creatures >= 2 && after_.creatures <= 3, "count rolled inside the range");
        assertEq(after_.creaturesLo, after_.creatures, "range collapsed: lo == value");
        assertEq(after_.creaturesHi, after_.creatures, "range collapsed: hi == value");
        assertFalse(after_.surveyed, "a blind entry does NOT count as a survey");
        assertFalse(after_.rescuerPending, "rescuerPending cleared on reveal");
        assertTrue(after_.rescuerInside, "non-empty portal: rescuer entered");
        assertEq(_g().rescuersFree, 1, "rescuersFree unchanged from commit");
        assertFalse(harness.getPending(player).active, "pending cleared on reveal");
    }

    // ── 5.3: rolled zero — the rescuer does not enter and goes to recovery ────
    // Updated for Ticket 4.6: event emitted at reveal, not at commit.

    function test_5_3_BlindEntry_Empty_NoEntry_EventEmitted() public {
        Portal memory p = _unsurveyed();
        p.creaturesLo = 0;
        p.creaturesHi = 0; // forces a rolled count of exactly 0
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit
        assertEq(_g().rescuersFree, 1, "rescuer out of pool at commit");

        // hoursElapsed is 0 (no time has passed), cooldown is 10 -> return at hour 10.
        vm.expectEmit(true, true, false, true);
        emit PortalLab.RescuerRecovering(player, 0, 10);
        source.reveal(harness.getPending(player).requestId); // reveal emits event

        Portal memory after_ = _p(0);
        assertTrue(after_.creaturesKnown, "count is now known (zero)");
        assertEq(after_.creatures, 0, "empty");
        assertFalse(after_.rescuerInside, "rescuer never entered the empty portal");
        assertEq(_g().rescuersFree, 1, "rescuer left the pool for recovery");
    }

    // ── 5.4: the rescuer returns exactly once, exactly after the cooldown ─────
    // Updated for Ticket 4.6: act is now commit+reveal.

    function test_5_4_Cooldown_ReturnsOnceAtRightHour() public {
        Config memory c = DefaultConfig.config();
        Portal memory p = _unsurveyed();
        p.creaturesLo = 0;
        p.creaturesHi = 0;
        p.hoursToCollapse = 200; // survive the whole test window
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit: hour 0, rescuer out
        source.reveal(harness.getPending(player).requestId); // reveal: cooldown cell = hour 10
        assertEq(_g().rescuersFree, 1);

        // Hour 9: still recovering.
        vm.warp(BASE + 9 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 1, "not back before the cooldown elapses");

        // Hour 10: rejoins the pool.
        vm.warp(BASE + 10 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 2, "back exactly at hour 10");

        // Hour 20: does not return a second time and never exceeds the total.
        vm.warp(BASE + 20 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 2, "returns exactly once");
        assertLe(_g().rescuersFree, c.rescuersTotal, "never exceeds rescuersTotal");
    }

    // ── 5.5: two empty entries occupy two cells and return each at its hour ───
    // Updated for Ticket 4.6: each act is now commit+reveal.

    function test_5_5_TwoEmptyEntries_TwoCells_ReturnEachAtItsHour() public {
        Portal memory p0 = _unsurveyed();
        p0.creaturesLo = 0;
        p0.creaturesHi = 0;
        p0.hoursToCollapse = 200;

        Portal memory p1 = _unsurveyed();
        p1.creaturesLo = 0;
        p1.creaturesHi = 0;
        p1.hoursToCollapse = 200;

        Game memory g = _game();
        g.openPortals = 2;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p0);
        harness.setPortal(player, 1, p1);

        // First empty entry at hour 0 -> return at hour 10.
        harness.act(0, Action.SendRescuer);
        source.reveal(harness.getPending(player).requestId);
        assertEq(_g().rescuersFree, 1);

        // Second empty entry at hour 5 -> return at hour 15.
        vm.warp(BASE + 5 * SPH);
        harness.act(1, Action.SendRescuer);
        source.reveal(harness.getPending(player).requestId);
        assertEq(_g().rescuersFree, 0, "both rescuers are now recovering (two cells)");

        // Hour 10: first cell matures.
        vm.warp(BASE + 10 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 1, "first rescuer back at hour 10");

        // Hour 15: second cell matures.
        vm.warp(BASE + 15 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 2, "second rescuer back at hour 15");

        // Hour 25: no spurious extra returns.
        vm.warp(BASE + 25 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 2, "both returned exactly once");
    }

    // ── 5.6: blind evacuation leaves one behind; n=1 saves nobody ─────────────
    // These tests start with rescuerInside=true already set — they exercise
    // the evacuation action, not the blind rescue commit/reveal. No change needed.

    function test_5_6_BlindEvacuate_LeavesOne() public {
        // Blind-entered portal: unsurveyed, count known, rescuer inside, 3 creatures.
        Portal memory p = _unsurveyed();
        p.creaturesKnown = true;
        p.creatures = 3;
        p.creaturesLo = 3;
        p.creaturesHi = 3;
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);

        harness.act(0, Action.Evacuate);

        Portal memory after_ = _p(0);
        assertEq(after_.creatures, 1, "one is always left behind in the dark");
        assertEq(_g().hp, 56, "healed for the 2 saved (50 + 2*3)");
        assertEq(_g().rescuersFree, 2, "rescuer returned");
    }

    function test_5_6_BlindEvacuate_OneCreature_SavesNone() public {
        Portal memory p = _unsurveyed();
        p.creaturesKnown = true;
        p.creatures = 1;
        p.creaturesLo = 1;
        p.creaturesHi = 1;
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);

        harness.act(0, Action.Evacuate);

        Portal memory after_ = _p(0);
        assertEq(after_.creatures, 1, "the single creature stays: n-1 = 0 saved");
        assertEq(_g().hp, 50, "no healing");
        assertEq(_g().rescuersFree, 2, "rescuer still returns");
    }

    // ── 5.7: a surveyed portal is evacuated completely ────────────────────────

    function test_5_7_SurveyedEvacuate_TakesAll() public {
        Portal memory p = _unsurveyed();
        p.surveyed = true; // surveyed -> full evacuation
        p.creaturesKnown = true;
        p.creatures = 3;
        p.creaturesLo = 3;
        p.creaturesHi = 3;
        p.rescuerInside = true;
        Game memory g = _game();
        g.hp = 50;
        g.rescuersFree = 1;
        _write(g, p);

        harness.act(0, Action.Evacuate);

        assertEq(_p(0).creatures, 0, "surveyed evacuation takes everyone");
        assertEq(_g().hp, 59, "healed for all 3 (50 + 3*3)");
    }

    // ── 5.8: the cautious estimate blocks the rescuer in a dangerous portal ───

    function test_5_8_CautiousRisk_BlocksRescuer() public {
        Portal memory p = _unsurveyed();
        // Worst corner is lethal: no stability, full energy, about to collapse.
        p.stabilityLo = 0;
        p.stabilityHi = 100;
        p.energyLo = 0;
        p.energyHi = 100;
        p.hoursToCollapse = 1;
        p.creaturesLo = 0;
        p.creaturesHi = 5;
        _write(_game(), p);

        assertEq(uint8(harness.canAct(player, 0, Action.SendRescuer)), uint8(Refusal.RiskTooHigh));
    }

    // ── 5.9: the same estimate does NOT block the observer (anti-deadlock) ────

    function test_5_9_CautiousRisk_DoesNotBlockObserver() public {
        Portal memory p = _unsurveyed();
        p.stabilityLo = 0;
        p.stabilityHi = 100;
        p.energyLo = 0;
        p.energyHi = 100;
        p.hoursToCollapse = 1;
        p.creaturesLo = 0;
        p.creaturesHi = 5;
        _write(_game(), p);

        // Observing IS surveying: it must stay open, or the portal is a dead end.
        assertEq(uint8(harness.canAct(player, 0, Action.SendObserver)), uint8(Refusal.None));
    }

    // ── 5.10: deploying with rescuersTotal > MAX_RESCUERS reverts ─────────────

    function test_5_10_Deploy_RejectsTooManyRescuers() public {
        Config memory c = DefaultConfig.config();
        c.rescuersTotal = 5; // MAX_RESCUERS is 4
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        DeterministicSource s = harness.source();

        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "rescuersTotal"));
        new PortalLab(c, params, s);
    }

    function test_5_10_Deploy_RejectsZeroCooldown() public {
        // A zero cooldown collides with "cell free" (0) at game hour 0, losing the
        // recovering rescuer — forbidden at deploy.
        Config memory c = DefaultConfig.config();
        c.rescuerCooldownHours = 0;
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        DeterministicSource s = harness.source();

        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "rescuerCooldownHours"));
        new PortalLab(c, params, s);
    }

    // ── 5.11: preview matches sync, including a rescuer returning from recovery ─
    // Updated for Ticket 4.6: act is now commit+reveal.

    function test_5_11_PreviewMatchesSync_AcrossRecovery() public {
        Portal memory p = _unsurveyed();
        p.creaturesLo = 0;
        p.creaturesHi = 0;
        p.hoursToCollapse = 200;
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit
        source.reveal(harness.getPending(player).requestId); // reveal: return scheduled for hour 10

        // Jump past the return hour and compare the projection to the committed state.
        vm.warp(BASE + 12 * SPH);

        (Game memory pg, Portal[MAX_OPEN_PORTALS] memory pp,) = harness.preview(player);
        harness.sync(player);
        Game memory sg = harness.getGame(player);
        Portal[MAX_OPEN_PORTALS] memory sp = harness.getPortals(player);

        assertEq(keccak256(abi.encode(pg)), keccak256(abi.encode(sg)), "preview game == synced game");
        assertEq(keccak256(abi.encode(pp)), keccak256(abi.encode(sp)), "preview portals == synced portals");
        assertEq(pg.rescuersFree, 2, "recovery reflected identically in preview and sync");
    }

    // ── NEW TEST 5.1 (Ticket 4.6): commit+reveal, power and rescuer at commit ─

    function test_BlindRescue_InEpoch_CommitState() public {
        _write(_game(), _unsurveyed()); // creaturesLo=2, creaturesHi=3 (always >= 1)

        harness.act(0, Action.SendRescuer); // commit

        // After commit: power deducted, rescuer out of pool, pending active.
        assertEq(_g().power, 80, "power deducted at commit: 100 - 20");
        assertEq(_g().rescuersFree, 1, "rescuer left pool at commit: 2 - 1");
        assertTrue(harness.getPending(player).active, "pending active after commit");
        assertEq(uint8(harness.getPending(player).action), uint8(Action.SendRescuer), "pending action is SendRescuer");
        assertTrue(_p(0).rescuerPending, "rescuerPending flag set at commit");
        assertFalse(_p(0).creaturesKnown, "count not known before reveal");
        assertFalse(_p(0).rescuerInside, "rescuer not inside before reveal");

        source.reveal(harness.getPending(player).requestId); // reveal

        // After reveal: creatures known, rescuer entered (range 2-3, always >= 1).
        assertTrue(_p(0).creaturesKnown, "creatures known after reveal");
        assertTrue(_p(0).rescuerInside, "rescuer entered non-empty portal");
        assertFalse(_p(0).rescuerPending, "rescuerPending cleared on reveal");
        assertFalse(harness.getPending(player).active, "pending cleared on reveal");
        assertEq(_g().rescuersFree, 1, "rescuersFree unchanged from commit");
        assertEq(_g().power, 80, "power unchanged from commit");
    }

    // ── NEW TEST 5.2 (Ticket 4.6): zero creature result → cooldown 10 hours ──

    function test_BlindRescue_ZeroCreatures_Cooldown() public {
        Portal memory p = _unsurveyed();
        p.creaturesLo = 0;
        p.creaturesHi = 0; // forces count = 0
        p.hoursToCollapse = 200;
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit
        assertEq(_g().rescuersFree, 1, "rescuer out of pool at commit");
        assertEq(_g().power, 80, "power deducted at commit");

        vm.expectEmit(true, true, false, true);
        emit PortalLab.RescuerRecovering(player, 0, 10); // atHour(0) + cooldown(10) = 10
        source.reveal(harness.getPending(player).requestId); // reveal emits the event

        assertFalse(_p(0).rescuerInside, "rescuer never entered empty portal");
        assertTrue(_p(0).creaturesKnown, "count now known (zero)");
        assertEq(_p(0).creatures, 0, "portal confirmed empty");
        assertEq(_g().rescuersFree, 1, "rescuer in cooldown, not yet returned");
        assertFalse(harness.getPending(player).active, "pending cleared");

        // Rescuer returns after cooldown (10 hours).
        vm.warp(BASE + 10 * SPH);
        harness.sync(player);
        assertEq(_g().rescuersFree, 2, "rescuer returned after 10-hour cooldown");
    }

    // ── NEW TEST 5.3 (Ticket 4.6): epoch-crossing blind rescue — one request ──

    function test_BlindRescue_EpochCrossing() public {
        uint32 SPH_conf = DefaultConfig.config().secPerHour;

        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
        harness.setGame(player, g);
        // coveredEpochs = 0: any time past BASE causes cappedShort.
        harness.setCoverage(player, uint256(keccak256("seed")), 0);

        Portal memory p = _unsurveyed(); // creaturesLo=2, creaturesHi=3
        harness.setPortal(player, 0, p);

        // Warp 1 hour: coveredEpochs = 0, so cappedShort = true → epoch-crossing path.
        vm.warp(BASE + SPH_conf);

        harness.act(0, Action.SendRescuer); // epoch-crossing commit: deferredWorld = true
        assertTrue(harness.getPending(player).active, "pending active");
        assertTrue(harness.getPending(player).deferredWorld, "epoch-crossing: deferredWorld");

        uint64 reqId = harness.getPending(player).requestId;

        // Only ONE request was made (not two — word serves both spawn and rescue).
        assertEq(reqId, 1, "exactly one request for the crossing");

        source.reveal(reqId); // reveal: _revealCrossing → _performDeferredAction → blind rescue

        // After reveal: rescuer entered, power and rescuersFree applied.
        assertTrue(harness.getPortals(player)[0].rescuerInside, "rescuer entered after epoch-crossing reveal");
        assertEq(harness.getGame(player).rescuersFree, 1, "rescuersFree decremented at reveal");
        assertFalse(harness.getPending(player).active, "pending cleared");
    }

    // ── NEW TEST 5.4 (Ticket 4.6): cancel — portal collapsed, power+rescuer returned

    function test_BlindRescue_Cancel_PortalCollapsed() public {
        Portal memory p = _unsurveyed();
        p.creaturesLo = 2;
        p.creaturesHi = 3;
        p.hoursToCollapse = 1; // collapses at hour 1
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // commit at hour 0
        uint64 reqId = harness.getPending(player).requestId;

        // After commit: power deducted, rescuer committed.
        assertEq(_g().power, 80, "power deducted at commit");
        assertEq(_g().rescuersFree, 1, "rescuer out at commit");

        // Warp to hour 2: portal has collapsed (hoursToCollapse = 1).
        vm.warp(BASE + 2 * SPH);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(
            player, 0, Action.SendRescuer, Refusal.PortalEmpty, reqId, 2
        );
        source.reveal(reqId); // cancel: portal is gone

        // Power restored, rescuer returned.
        assertEq(_g().power, 100, "power refunded on cancel: 80 + 20 = 100");
        assertEq(_g().rescuersFree, 2, "rescuer returned to pool on cancel");
        assertFalse(harness.getPending(player).active, "deferral resolved");
    }

    // ── NEW TEST 5.5 (Ticket 4.6): sighted rescuer stays single-phase ─────────

    function test_BlindRescue_Sighted_SinglePhase() public {
        Portal memory p = _unsurveyed();
        p.creaturesKnown = true; // sighted: count already known
        p.creatures = 2;
        p.creaturesLo = 2;
        p.creaturesHi = 2;
        _write(_game(), p);

        harness.act(0, Action.SendRescuer); // single-phase: no deferral

        assertFalse(harness.getPending(player).active, "no deferral for sighted rescue");
        assertTrue(_p(0).rescuerInside, "rescuer entered immediately");
        assertEq(_g().rescuersFree, 1, "rescuersFree decremented");
        assertEq(_g().power, 80, "power deducted");
    }

    // ── NEW TEST 5.6 (Ticket 4.6): gas for blind rescue reveal (worst case) ───

    function test_BlindRescue_Gas_RevealWorstCase() public {
        // Fill all portal slots to maximize catch-up work.
        Game memory g = _game();
        g.openPortals = 12; // MAX_OPEN_PORTALS
        g.rescuersFree = 2;
        harness.setGame(player, g);

        for (uint8 i = 0; i < 12; i++) {
            Portal memory p = _unsurveyed();
            if (i == 0) {
                p.creaturesLo = 2;
                p.creaturesHi = 3; // target portal for blind rescue
            } else {
                p.creaturesLo = 1;
                p.creaturesHi = 3;
            }
            harness.setPortal(player, i, p);
        }

        harness.act(0, Action.SendRescuer); // commit
        uint64 reqId = harness.getPending(player).requestId;

        uint256 gasBefore = gasleft();
        source.reveal(reqId);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("BlindRescue reveal gas (worst case, 12 portals)", gasUsed);

        assertLt(gasUsed, 1_000_000, "reveal must fit within 1M gas hard limit");
    }
}
