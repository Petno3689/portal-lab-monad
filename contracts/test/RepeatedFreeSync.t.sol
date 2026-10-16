// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Game, Portal, Config, MAX_OPEN_PORTALS} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title RepeatedFreeSyncTest — outside free syncs change nothing. The hole is
///                               CLOSED. READ THIS FIRST.
///
///  * The hole. `sync(player)` is free, unauthenticated, and open to anyone. A
///    portal used to be born at `hWalkEnd` — the hour of whatever call happened
///    to age the world — so whoever chose the call moment chose when portals were
///    born. Portals born ahead of schedule had time to collapse, and every
///    collapse costs HP: ONE outside call at a chosen hour could kill a run that
///    would otherwise have survived (measured by the reviewer on the second stand
///    below: in 17 of 30 pairs the run was alive without the call and dead with
///    it; in the other 13 it died earlier with it).
///  * Why it is closed. A portal's birth hour is now a function of time and state
///    alone: the k-th portal of a window is born at the first hour its pressure
///    matures (`debt0 + spawnPressure(h0, h) >= k * spawnCostUnits`) with a slot
///    free — never at the hour of a call. Every event hour (collapses and births)
///    therefore follows from the stored snapshot and the clock, and a catch-up to
///    `c` leaves the same world whether or not anyone called at some `b` in
///    between. An outside call is just an observation.
///  * What this file pins. Every scenario compares the world WITH the outside
///    call(s) against the world WITHOUT them, byte for byte (game and all twelve
///    portals). The generic proof over many states and every intermediate second
///    is BirthAtMaturity.t.sol; this file keeps the original stands and the
///    pinned word, so the finding and its repair can be read side by side.
///
/// History, kept deliberately. Before any fix, repeated calls in ONE block spent a
/// victim's already accrued debt on portals ahead of schedule (a per-call spawn
/// cap, `maxSpawnsPerTx`, capped a call, not a moment): six stranger syncs at hour
/// 113 opened 11 portals instead of 3 and moved the death from hour 134 to 123. A
/// first fix made repeats in one moment useless but left the single outside call
/// lethal (section 6 as it then stood). The per-call cap is gone now; births are
/// not tied to calls at all.
///
/// The numbers changed with the rule, and not only because the hole closed: an
/// abandoned lab now really fills — portals are born at maturity during the
/// absence and collapse — so the first stand, untouched, dies at hour 57 rather
/// than at the old analytic hour 134 (and at hour 49 since epochHours 12 -> 36).
///
/// If a test here fails, the world again depends on WHEN someone calls. Do not
/// update the numbers to match; find out why.
///
/// Fixture: stand configuration (GameConfig defaults), player with hp 100, full
/// crew and full power, empty lab, a word already issued with 100 covered
/// epochs, game started at BASE.
contract RepeatedFreeSyncTest is Test {
    PortalLabHarness internal harness;
    address internal player;
    address internal stranger;

    uint40 internal constant BASE = 1000;
    uint32 internal SPH;

    struct World {
        Game g;
        Portal[MAX_OPEN_PORTALS] p;
    }

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(0xA11CE);
        stranger = address(0xBAD);
        Config memory c = DefaultConfig.config();
        SPH = c.secPerHour;
        vm.warp(BASE);
        _seed();
    }

    /// @dev hp 100 and 100 covered epochs are not reachable through real calls
    /// (startGame gives hpStart 80; a word covers only the epochs up to its
    /// request), so this state is seeded with the harness setters.
    function _seed() internal {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("repeated-free-sync")), 100);
    }

    function _warpHours(uint256 h) internal {
        vm.warp(uint256(BASE) + h * SPH);
    }

    function _game() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _world() internal view returns (World memory w) {
        w.g = harness.getGame(player);
        w.p = harness.getPortals(player);
    }

    function _assertSameWorld(World memory a, World memory b, string memory what) internal pure {
        assertEq(abi.encode(a.g), abi.encode(b.g), string.concat(what, ": game"));
        for (uint256 s = 0; s < MAX_OPEN_PORTALS; s++) {
            assertEq(abi.encode(a.p[s]), abi.encode(b.p[s]), string.concat(what, ": portal"));
        }
    }

    // ── 1. one free sync after a 113-hour absence ────────────────────────────

    /// The abandoned lab filled and died long before the call: five portals were
    /// born at their maturity hours (10, 20, 30, 39, 48), newborns collapsed, and
    /// the run ended at hour 53 (it was 49 before hpStart 80, hpCollapsePerDeath 8
    /// and pressureRampPerHour 2). Debt at death: P(0,53) = 55_756, less 5 * 10_000.
    function test_OneFreeSyncAfter113Hours() public {
        _warpHours(113);
        harness.sync(player);
        Game memory g = _game();
        assertTrue(g.finished, "one sync: the abandoned lab is dead");
        assertEq(uint256(g.diedAtHour), 53, "one sync: died at hour 53");
        assertEq(uint256(g.spawnCount), 5, "one sync: five births");
        assertEq(uint256(g.openPortals), 1, "one sync: portals open at death");
        assertEq(uint256(g.spawnDebt), 5_756, "one sync: debt at the death hour"); // 55_756 - 5*10_000
        assertEq(uint256(g.hp), 0, "one sync: hp");
    }

    // ── 2. six free syncs, one block, a non-player address ───────────────────

    function test_SixFreeSyncsInOneBlockFromStrangerEqualOne() public {
        uint256 snap = vm.snapshotState();
        _warpHours(113);
        harness.sync(player);
        World memory one = _world();
        vm.revertToState(snap);

        _warpHours(113);
        uint256 ts = vm.getBlockTimestamp();
        assertTrue(stranger != player, "caller is not the player");
        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
            assertEq(vm.getBlockTimestamp(), ts, "block.timestamp did not move between calls");
        }
        vm.stopPrank();

        _assertSameWorld(_world(), one, "six syncs == one sync");
    }

    // ── 3. the original finding: same time, same world ───────────────────────

    /// Scenario A — nobody interferes; the player syncs at hour 153.
    function _scenarioA() internal returns (World memory) {
        _warpHours(153);
        harness.sync(player);
        return _world();
    }

    /// Scenario B — a stranger syncs six times at hour 113; the player syncs at
    /// hour 153. The total passage of time is IDENTICAL to A.
    function _scenarioB() internal returns (World memory) {
        _warpHours(113);
        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
        }
        vm.stopPrank();
        _warpHours(153);
        harness.sync(player);
        return _world();
    }

    function test_ScenarioA_NobodyInterferes() public {
        Game memory g = _scenarioA().g;
        assertTrue(g.finished, "A: dead by hour 153");
        assertEq(uint256(g.diedAtHour), 53, "A: died at hour 53");
        assertEq(uint256(g.openPortals), 1, "A: portals open at death");
        assertEq(uint256(g.spawnDebt), 5_756, "A: debt at the death hour"); // 55_756 - 5*10_000
    }

    function test_ScenarioB_EqualsScenarioA() public {
        uint256 snap = vm.snapshotState();
        World memory a = _scenarioA();
        vm.revertToState(snap);
        World memory b = _scenarioB();
        _assertSameWorld(b, a, "six outside syncs at hour 113 change nothing");
    }

    // ── 4. 200-hour absence: repeats after the end are no-ops ────────────────

    function test_200HourAbsenceFirstSyncEndsGameAndRepeatsAreNoOps() public {
        _warpHours(200);
        harness.sync(player);
        World memory first = _world();
        assertTrue(first.g.finished, "first sync ends the game");
        assertEq(uint256(first.g.diedAtHour), 53, "died at hour 53");

        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
        }
        vm.stopPrank();

        _assertSameWorld(_world(), first, "repeated syncs change nothing");
    }

    // ── 5. one outside sync == six == none ───────────────────────────────────

    function test_OneOutsideSyncEqualsSixEqualsNone() public {
        uint256 snap = vm.snapshotState();
        World memory untouched = _scenarioA();
        vm.revertToState(snap);

        _warpHours(113);
        vm.prank(stranger);
        harness.sync(player);
        _warpHours(153);
        harness.sync(player);
        World memory touched = _world();
        _assertSameWorld(touched, untouched, "one outside sync == none");

        vm.revertToState(snap);
        _assertSameWorld(_scenarioB(), touched, "six outside syncs == one");
    }

    // ── 6. the former open hole: one outside sync at a chosen hour ───────────

    /// Second stand, values the game itself produces: hp 50 (what startGame
    /// gives), power 50, 3 observers, 2 rescuers, empty lab, word issued,
    /// 12 covered epochs, started at BASE. The word stays pinned: it decides the
    /// types of the portals that drop and, through them, when they collapse.
    function _seedLethalStand() internal {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 50;
        g.power = 50;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("repeated-free-sync")), 12);
    }

    /// The outcome with one outside call at `outsideHour` EQUALS the outcome
    /// without it — game and all twelve portals — whatever that outcome is. These
    /// were the two lethal representatives of the reviewer's 30-pair sweep; a
    /// third, earlier pair is added where the run is still alive at the final
    /// sync. `wantFinished` / `wantDeathHour` document what the stand does now;
    /// the equality is the point.
    function _outsideCallChangesNothing(uint256 outsideHour, uint256 finalHour, bool wantFinished, uint32 wantDeathHour)
        internal
    {
        _seedLethalStand();
        uint256 snap = vm.snapshotState();

        // No interference: the player syncs once at finalHour.
        _warpHours(finalHour);
        harness.sync(player);
        World memory clean = _world();

        // One outside call at outsideHour, then the player at finalHour.
        vm.revertToState(snap);
        _warpHours(outsideHour);
        vm.prank(stranger);
        harness.sync(player);
        _warpHours(finalHour);
        harness.sync(player);
        World memory hit = _world();

        _assertSameWorld(hit, clean, "one outside call changes nothing");
        assertEq(clean.g.finished, wantFinished, "outcome: finished");
        assertEq(uint256(clean.g.diedAtHour), uint256(wantDeathHour), "outcome: death hour");
    }

    function test_HOLE_CLOSED_OneOutsideSyncAtHour20ChangesNothing() public {
        _outsideCallChangesNothing(20, 60, true, 38);
    }

    function test_HOLE_CLOSED_OneOutsideSyncAtHour60ChangesNothing() public {
        _outsideCallChangesNothing(60, 120, true, 38);
    }

    function test_HOLE_CLOSED_OneOutsideSyncAtHour5ChangesNothing_RunAlive() public {
        _outsideCallChangesNothing(5, 20, false, 0);
    }
}
