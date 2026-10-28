// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Portal, PortalType, PortalStatus, Action, Refusal} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title TimeTest — fifteen groups covering lazy time (SPEC §5).
/// @notice State is prepared through `PortalLabHarness`. Structs are built fresh
/// by helpers (never assigned by copy — CLAUDE.md rule). All numbers below match
/// `DefaultConfig`: secPerHour 15, hpMax 100, hpCollapseBase 20,
/// hpCollapsePerDeath 8, hpEmptyCollapse 3, hpOverflowPerHour 5,
/// powerMax 100, powerRegenPerHour 5; degrade per hour: Flash 6, Deaf 3,
/// Energetic 3 (yield 4).
contract TimeTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000; // game start timestamp
    uint40 internal constant SPH = 15; // seconds per game hour

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Active game anchored at BASE: hp 100, power 100, full crew.
    function _g() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
    }

    /// @dev Open, surveyed Flash portal snapshotted at BASE: stability 100,
    /// energy 50, 100 h to collapse, no creatures.
    function _p() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true; // surveyed => creatures count is exact
        p.stability = 100;
        p.energy = 50;
        p.hoursToCollapse = 100;
        p.snapshotAt = BASE;
    }

    /// @dev Warp to `h` game hours after BASE.
    function _warpHours(uint40 h) internal {
        vm.warp(BASE + h * SPH);
    }

    function _game_() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _portal_(uint8 slot) internal view returns (Portal memory) {
        return harness.getPortals(player)[slot];
    }

    // ── Group 1: No time passed ──────────────────────────────────────────────

    function test_NoTime_SyncIsNoop() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.stability = 80;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        harness.sync(player); // now == BASE, nothing elapsed

        assertEq(_game_().hp, 100);
        assertEq(_game_().power, 100);
        assertEq(_game_().hoursElapsed, 0);
        assertEq(_portal_(0).stability, 80);
        assertEq(_portal_(0).hoursToCollapse, 100);
    }

    // ── Group 2: Degradation of a surveyed portal ────────────────────────────

    function test_Degradation() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.portalType = PortalType.Deaf; // degrade 3/h
        p.stability = 100;
        p.hoursToCollapse = 200; // survives the window
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(10);
        harness.sync(player);
        assertEq(_portal_(0).stability, 70); // 100 - 3*10
    }

    function test_Degradation_FloorsAtZero() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.portalType = PortalType.Deaf; // degrade 3/h
        p.stability = 100;
        p.hoursToCollapse = 200;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(100);
        harness.sync(player);
        assertEq(_portal_(0).stability, 0); // 100 - 300 -> floored, not negative
    }

    // ── Group 3: Unsurveyed portal ───────────────────────────────────────────

    function test_Unsurveyed_TimeOnly() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.surveyed = false;
        p.stability = 80; // must NOT change (field unused while unsurveyed)
        p.hoursToCollapse = 50;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(10);
        harness.sync(player);
        assertEq(_portal_(0).hoursToCollapse, 40); // 50 - 10
        assertEq(_portal_(0).stability, 80); // untouched
    }

    // ── Group 4: Empty surveyed portal collapses ─────────────────────────────

    function test_Collapse_EmptySurveyed() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.creatures = 0;
        p.hoursToCollapse = 5;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(5);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalCollapsed(player, 0, 0, 3, 5); // deaths 0, hpLost hpEmptyCollapse=3, atHour 5
        harness.sync(player);

        assertEq(_game_().hp, 97); // 100 - 3
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Empty));
        assertEq(_game_().openPortals, 0);
    }

    // ── Group 5: Collapse with beings inside ─────────────────────────────────

    function test_Collapse_WithLiving() public {
        Game memory g = _g();
        g.openPortals = 1;
        g.observersFree = 2; // one inside
        g.rescuersFree = 1; // one inside
        Portal memory p = _p();
        p.creatures = 2;
        p.observerInside = true;
        p.rescuerInside = true;
        p.hoursToCollapse = 3;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(3);
        harness.sync(player);

        // deaths = 2 + observer + rescuer = 4; hpLost = 20 + 8*4 = 52.
        assertEq(_game_().hp, 48); // 100 - 52
        // Dead crew does NOT return to the pool.
        assertEq(_game_().observersFree, 2);
        assertEq(_game_().rescuersFree, 1);
        assertEq(_game_().openPortals, 0);
    }

    // ── Group 6: Collapse of an unsurveyed portal uses the range ──────────────

    function test_Collapse_Unsurveyed_UsesRange() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.surveyed = false;
        p.creaturesKnown = false; // unsurveyed: exact count unknown, use range midpoint
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        p.creatures = 9; // MUST be ignored for an unsurveyed portal
        p.hoursToCollapse = 4;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(4);
        harness.sync(player);

        // deaths = (1 + 4) / 2 = 2; hpLost = 20 + 8*2 = 36. If `creatures` (9)
        // were read, hpLost would be 20 + 72 = 92 and hp would be 8, not 64.
        assertEq(_game_().hp, 64); // 100 - 36
    }

    // ── Group 7: Collapses are ordered; death fixes at the FIRST ──────────────

    function test_Order_DeathAtFirstCollapse() public {
        Game memory g = _g();
        g.hp = 50;
        g.openPortals = 2;
        harness.setGame(player, g);

        Portal memory a = _p();
        a.creatures = 4; // deaths 4 -> hpLost 20 + 8*4 = 52 (>= hp 50)
        a.hoursToCollapse = 3; // collapses at hour 3
        harness.setPortal(player, 0, a);

        Portal memory b = _p();
        b.creatures = 4;
        b.hoursToCollapse = 5; // collapses at hour 5
        harness.setPortal(player, 1, b);

        _warpHours(5); // both are due
        harness.sync(player);

        // Ascending order collapses A (hour 3) first, which kills. A reversed
        // order would report hour 5 — the chosen numbers make the two distinct.
        assertEq(_game_().diedAtHour, 3);
        assertEq(_game_().hoursElapsed, 3);
        assertTrue(_game_().finished);
    }

    // ── Group 8: Overflow with 12 open portals ───────────────────────────────

    function _fillTwelve(uint16 hp) internal {
        Game memory g = _g();
        g.hp = hp;
        g.openPortals = 12;
        harness.setGame(player, g);
        for (uint8 i = 0; i < 12; i++) {
            Portal memory p = _p();
            p.creatures = 0;
            p.hoursToCollapse = 1000; // none collapse in the window
            harness.setPortal(player, i, p);
        }
    }

    function test_Overflow_Partial() public {
        _fillTwelve(50);
        _warpHours(5);
        harness.sync(player);
        assertEq(_game_().hp, 25); // 50 - 5*5
        assertTrue(!_game_().finished);
    }

    function test_Overflow_Death() public {
        _fillTwelve(50);
        _warpHours(10);
        harness.sync(player);
        assertEq(_game_().hp, 0); // 50 - 5*10
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 10); // ceil(50/5) = 10 hours in
    }

    function test_Overflow_DeathHourRoundsUp() public {
        // 52 HP at 5/hour: alive at hour 10 with 2 HP left, dead at hour 11.
        // With flooring instead of ceiling the score would be one hour short.
        _fillTwelve(52);
        _warpHours(11);
        harness.sync(player);
        assertEq(_game_().hp, 0);
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 11, "ceil(52/5) = 11");
    }

    function test_Overflow_StopsAfterCollapse() public {
        // 12 portals open → overflow penalty active (hpOverflowPerHour = 5).
        // Portal 0 collapses at hour 1 (empty → hpEmptyCollapse = 3).
        // After the collapse only 11 portals remain → overflow must stop,
        // and g.openPortals must reflect the new count.
        Game memory g = _g();
        g.hp = 100;
        g.openPortals = 12;
        harness.setGame(player, g);

        for (uint8 i = 0; i < 12; i++) {
            Portal memory p = _p();
            p.creatures = 0;
            p.hoursToCollapse = (i == 0) ? 1 : 1000;
            harness.setPortal(player, i, p);
        }

        // Warp 3 hours: overflow active for h0→h1 (1 hour, -5 HP), then portal 0
        // collapses (-3 HP), then h1→h3 has only 11 portals (no overflow).
        _warpHours(3);
        harness.sync(player);

        assertEq(_game_().openPortals, 11);
        assertEq(_game_().hp, 92); // 100 - 5 (overflow 1h) - 3 (empty collapse)
        assertTrue(!_game_().finished);
    }

    // ── Group 9: Death while the player is away (the core test) ──────────────

    function test_DeathInAbsence_ScoreAtDeathNotReturn() public {
        Game memory g = _g();
        g.hp = 50;
        g.openPortals = 1;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.creatures = 4; // deaths 4 -> hpLost 20 + 8*4 = 52 >= hp 50
        p.hoursToCollapse = 3; // collapses (and kills) at hour 3
        harness.setPortal(player, 0, p);

        // Player returns FAR later.
        _warpHours(100_000);
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameOver(player, 3);
        harness.sync(player);

        assertEq(_game_().diedAtHour, 3); // the hour of death, not of return
        assertEq(_game_().hoursElapsed, 3);
        assertEq(_game_().hoursElapsed, _game_().diedAtHour);
        assertTrue(_game_().finished);
    }

    // ── Group 10: After death, further sync does nothing ─────────────────────

    function test_AfterDeath_SyncIsNoop() public {
        Game memory g = _g();
        g.hp = 50;
        g.openPortals = 1;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.creatures = 4;
        p.hoursToCollapse = 3;
        harness.setPortal(player, 0, p);

        _warpHours(100_000);
        harness.sync(player);
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 3);

        // Much later — nothing changes.
        _warpHours(200_000);
        harness.sync(player);
        assertEq(_game_().diedAtHour, 3);
        assertEq(_game_().hoursElapsed, 3);
        assertEq(_game_().hp, 0);
    }

    // ── Group 11: Resource regen, cap and energetic yield ────────────────────

    function test_Resource_RegenAndCap() public {
        Game memory g = _g();
        g.power = 50;
        g.openPortals = 0; // no portals: regen only
        harness.setGame(player, g);

        _warpHours(5);
        harness.sync(player);
        assertEq(_game_().power, 75); // 50 + 5*5

        _warpHours(20);
        harness.sync(player);
        assertEq(_game_().power, 100); // 75 + 15*5 = 150 -> capped at 100
    }

    function test_Resource_EnergeticYieldStopsOnCollapse() public {
        Game memory g = _g();
        g.power = 0;
        g.openPortals = 1;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.portalType = PortalType.Energetic; // yield 4/h
        p.creatures = 0;
        p.hoursToCollapse = 5; // collapses at hour 5
        harness.setPortal(player, 0, p);

        _warpHours(5);
        harness.sync(player);
        // Open the whole segment: rate = 5 (regen) + 4 (yield) = 9 over 5 h.
        assertEq(_game_().power, 45);
        assertEq(_game_().openPortals, 0); // energetic collapsed

        _warpHours(10);
        harness.sync(player);
        // Yield gone: rate = 5 over the next 5 h.
        assertEq(_game_().power, 70); // 45 + 5*5
    }

    // ── Group 12: `act` ages state before checking ───────────────────────────

    function test_Act_OnCollapsedPortal_Refused() public {
        Game memory g = _g();
        g.openPortals = 1;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.creatures = 0; // empty collapse: hpLost 3, game survives
        p.hoursToCollapse = 3;
        harness.setPortal(player, 0, p);

        _warpHours(3); // the portal has collapsed by now
        vm.expectRevert(abi.encodeWithSelector(PortalLab.ActionRefused.selector, Refusal.PortalEmpty));
        harness.act(0, Action.Stabilize);
    }

    function test_Act_CloseBecomesValidByTime() public {
        Game memory g = _g();
        g.openPortals = 1;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.stability = 50; // >= closeStabilityBelow(40): not closable by stability
        p.hoursToCollapse = 10; // > closeHoursAtMost(6): not closable yet
        harness.setPortal(player, 0, p);

        _warpHours(5); // hoursToCollapse -> 5 <= 6: now closable
        harness.act(0, Action.Close);

        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Empty));
        assertEq(_game_().openPortals, 0);
    }

    // ── Group 13: `preview` matches `sync` ───────────────────────────────────

    function _assertPreviewMatchesSync() internal {
        (Game memory gp, Portal[12] memory pp,) = harness.preview(player);
        harness.sync(player);
        Game memory gs = _game_();

        assertEq(gp.hp, gs.hp, "hp");
        assertEq(gp.power, gs.power, "power");
        assertEq(gp.hoursElapsed, gs.hoursElapsed, "hoursElapsed");
        assertEq(gp.diedAtHour, gs.diedAtHour, "diedAtHour");
        assertTrue(gp.finished == gs.finished, "finished");
        assertEq(gp.openPortals, gs.openPortals, "openPortals");
        assertEq(gp.observersFree, gs.observersFree, "observersFree");
        assertEq(gp.rescuersFree, gs.rescuersFree, "rescuersFree");

        for (uint8 i = 0; i < 12; i++) {
            Portal memory ps = _portal_(i);
            assertEq(uint8(pp[i].status), uint8(ps.status), "status");
            assertEq(pp[i].stability, ps.stability, "stability");
            assertEq(pp[i].energy, ps.energy, "energy");
            assertEq(pp[i].hoursToCollapse, ps.hoursToCollapse, "htc");
            assertEq(uint256(pp[i].snapshotAt), uint256(ps.snapshotAt), "snapshotAt");
            assertEq(pp[i].creatures, ps.creatures, "creatures");
            assertTrue(pp[i].surveyed == ps.surveyed, "surveyed");
        }
    }

    function test_PreviewMatchesSync_Ageing() public {
        Game memory g = _g();
        g.openPortals = 1;
        Portal memory p = _p();
        p.portalType = PortalType.Deaf;
        p.stability = 90;
        p.hoursToCollapse = 50;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        _warpHours(10);
        _assertPreviewMatchesSync();
    }

    function test_PreviewMatchesSync_Collapse() public {
        Game memory g = _g();
        g.openPortals = 2;
        harness.setGame(player, g);
        Portal memory a = _p();
        a.creatures = 1;
        a.hoursToCollapse = 3;
        harness.setPortal(player, 0, a);
        Portal memory b = _p();
        b.hoursToCollapse = 40;
        harness.setPortal(player, 1, b);

        _warpHours(5);
        _assertPreviewMatchesSync();
    }

    function test_PreviewMatchesSync_Death() public {
        Game memory g = _g();
        g.hp = 30;
        g.openPortals = 1;
        harness.setGame(player, g);
        Portal memory p = _p();
        p.creatures = 4; // hpLost 60 kills
        p.hoursToCollapse = 3;
        harness.setPortal(player, 0, p);

        _warpHours(9);
        _assertPreviewMatchesSync();
    }

    // ── Group 14: Long pause costs no more than a short one ───────────────────

    function _setupThree(address who) internal {
        Game memory g = _g();
        g.power = 0;
        g.openPortals = 3;
        harness.setGame(who, g);
        for (uint8 i = 0; i < 3; i++) {
            Portal memory p = _p();
            p.stability = 100;
            p.hoursToCollapse = 65_535; // uint16 max; never collapses in either window
            harness.setPortal(who, i, p);
        }
    }

    function test_Gas_LongPauseIsNotWorse() public {
        address short = address(0x5401);
        address long = address(0x1075);
        _setupThree(short);
        _setupThree(long);

        _warpHours(10);
        uint256 g0 = gasleft();
        harness.sync(short);
        uint256 usedShort = g0 - gasleft();

        _warpHours(60_000);
        uint256 g1 = gasleft();
        harness.sync(long);
        uint256 usedLong = g1 - gasleft();

        // O(portals), not O(hours): a 6,000x longer pause must not even double
        // the cost. A per-hour loop would blow past this (or run out of gas).
        assertLe(usedLong, usedShort * 2, "long pause is not O(portals)");
    }

    // ── Group 15: Fuzz — any pause is safe ───────────────────────────────────

    function testFuzz_CatchUpStaysInBounds(uint40 pauseSecs) public {
        pauseSecs = uint40(bound(uint256(pauseSecs), 0, 10_000_000));

        Game memory g = _g();
        g.hp = 100;
        g.power = 50;
        g.openPortals = 2;
        harness.setGame(player, g);

        Portal memory a = _p();
        a.creatures = 2;
        a.hoursToCollapse = 10;
        harness.setPortal(player, 0, a);

        Portal memory b = _p();
        b.surveyed = false;
        b.creaturesLo = 1;
        b.creaturesHi = 3;
        b.hoursToCollapse = 20;
        harness.setPortal(player, 1, b);

        vm.warp(BASE + pauseSecs);
        harness.sync(player); // must never revert

        Game memory gg = _game_();
        assertLe(gg.hp, 100, "hp <= hpMax");
        assertLe(gg.power, 100, "power <= powerMax");
        assertLe(uint256(gg.hoursElapsed), uint256(pauseSecs) / SPH, "hoursElapsed <= h(now)");
    }
}
