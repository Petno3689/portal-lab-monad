// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Game, Config} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title RepeatedFreeSyncTest — repeated free syncs create no extra portals.
///                               The hole itself is NOT closed. READ THIS FIRST.
///
///  * What the fix removed: catch-up spends spawn debt only when the world
///    actually advanced (`hWalkEnd > windowStart` in TimeLib step 5). Repeated
///    calls in one moment no longer multiply spawns: six equal one, byte for
///    byte (sections 2 and 5).
///  * What the fix did NOT remove: ONE outside sync, at an hour the outsider
///    picks, can still kill a run that would have survived without it. This is
///    an OPEN VULNERABILITY. Section 6 shows it with lethal numbers.
///  * The real mechanism: a portal's birth hour is `hWalkEnd`, i.e. the moment
///    somebody happened to call — not a function of time. Whoever chooses the
///    call moment chooses when portals are born; three portals born early have
///    time to collapse, and every collapse costs HP. While this holds, the
///    world is not a function of the pair (state, now).
///  * The question is OPEN. No decision on a real repair has been taken. Do not
///    read the passing tests below as "handled".
///
/// History of the finding, kept deliberately. `sync(player)` is free,
/// unauthenticated, and does not require the world to have moved. Before the
/// fix, with no new hours elapsed no new pressure accrued, yet step 5 still
/// spent the ALREADY ACCRUED debt on portals. `maxSpawnsPerTx` caps one CALL,
/// not a moment in time, so several calls in one block converted a victim's
/// whole debt into portals ahead of schedule. Measured then: six stranger syncs
/// at hour 113 opened 11 portals instead of 3 and moved the victim's death
/// from hour 134 to hour 123. The first fixture below is the one that finding
/// was measured on. Under the fix the same six syncs open 3 portals and the
/// death moves from 134 only to 135 — but that gentle number is an artifact of
/// that fixture, not a bound on the damage (section 6).
///
/// If a test here fails, the fix was weakened or the rule was changed. Do not
/// update the numbers to match; find out which.
///
/// Fixture: stand configuration (GameConfig defaults), player with hp 100, full
/// crew and full power, empty lab, a word already issued with 100 covered
/// epochs, game started at BASE. Numbers were measured by the reviewer.
contract RepeatedFreeSyncTest is Test {
    PortalLabHarness internal harness;
    address internal player;
    address internal stranger;

    uint40 internal constant BASE = 1000;
    uint32 internal SPH;

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
    /// (startGame gives hpStart 50; a word covers only the epochs up to its
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

    // ── 1. one free sync after a 113-hour absence ────────────────────────────

    function test_OneFreeSyncAfter113HoursOpensThreePortals() public {
        _warpHours(113);
        harness.sync(player);
        Game memory g = _game();
        assertEq(uint256(g.openPortals), 3, "one sync: capped at maxSpawnsPerTx");
        assertEq(uint256(g.spawnDebt), 89_328, "one sync: debt left");
        assertEq(uint256(g.hp), 100, "one sync: hp");
        assertFalse(g.finished, "one sync: alive");
    }

    // ── 2. six free syncs, one block, a non-player address ───────────────────

    function test_SixFreeSyncsInOneBlockFromStrangerOpenOnlyThreePortals() public {
        _warpHours(113);
        uint256 ts = vm.getBlockTimestamp();
        assertTrue(stranger != player, "caller is not the player");

        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
            assertEq(vm.getBlockTimestamp(), ts, "block.timestamp did not move between calls");
        }
        vm.stopPrank();

        Game memory g = _game();
        assertEq(vm.getBlockTimestamp(), ts, "same block timestamp throughout");
        // Identical to ONE sync (section 1): the five repeats moved no hour and
        // spent nothing.
        assertEq(uint256(g.openPortals), 3, "six syncs: same as one sync");
        assertEq(uint256(g.spawnDebt), 89_328, "six syncs: debt not spent by repeats");
        assertEq(uint256(g.hp), 100, "six syncs: hp not yet touched");
        assertFalse(g.finished, "six syncs: alive");
    }

    // ── 3. the finding, under the fix: same time, nearly the same death ──────

    /// Scenario A — nobody interferes; the player syncs at hour 153.
    function _scenarioA() internal returns (Game memory) {
        _warpHours(153);
        harness.sync(player);
        return _game();
    }

    /// Scenario B — a stranger syncs six times at hour 113; the player syncs at
    /// hour 153. The total passage of time is IDENTICAL to A.
    function _scenarioB() internal returns (Game memory) {
        _warpHours(113);
        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
        }
        vm.stopPrank();
        _warpHours(153);
        harness.sync(player);
        return _game();
    }

    function test_ScenarioA_NobodyInterferes() public {
        Game memory g = _scenarioA();
        assertTrue(g.finished, "A: dead by hour 153");
        assertEq(uint256(g.openPortals), 3, "A: portals open");
        assertEq(uint256(g.spawnDebt), 134_628, "A: debt");
        assertEq(uint256(g.diedAtHour), 134, "A: died at hour 134");
    }

    function test_ScenarioB_StrangerSyncsSixTimesAtHour113() public {
        Game memory g = _scenarioB();
        assertTrue(g.finished, "B: dead by hour 153");
        assertEq(uint256(g.openPortals), 0, "B: portals open");
        assertEq(uint256(g.spawnDebt), 89_328, "B: debt");
        assertEq(uint256(g.diedAtHour), 135, "B: died at hour 135");
    }

    /// The finding, re-checked: the same victim, the same elapsed time, the
    /// same final sync. Before the fix six outside calls moved the death from
    /// hour 134 to hour 123; now the five repeats do nothing and only the first
    /// call remains. This shows that REPEATS no longer multiply — it does not
    /// show the hole is closed; see section 6.
    function test_RepeatedStrangerSyncsNoLongerMultiply_OnThisFixture() public {
        uint256 snap = vm.snapshotState();
        uint32 deathA = _scenarioA().diedAtHour;
        vm.revertToState(snap);
        uint32 deathB = _scenarioB().diedAtHour;

        assertEq(uint256(deathA), 134, "without interference: hour 134");
        assertEq(uint256(deathB), 135, "with six outside syncs: hour 135");
        assertGe(uint256(deathB), uint256(deathA), "on this fixture the repeats cost no extra hours");
    }

    // ── 4. 200-hour absence: the boundary beyond which influence is impossible ─

    function test_200HourAbsenceFirstSyncEndsGameAndRepeatsAreNoOps() public {
        _warpHours(200);
        harness.sync(player);
        Game memory first = _game();
        assertTrue(first.finished, "first sync ends the game (section 5.5)");
        assertEq(uint256(first.diedAtHour), 134, "died at hour 134");

        vm.startPrank(stranger);
        for (uint256 i = 0; i < 6; i++) {
            harness.sync(player);
        }
        vm.stopPrank();

        Game memory after_ = _game();
        assertEq(abi.encode(after_), abi.encode(first), "repeated syncs change nothing");
    }

    // ── 5. residual influence: one outside sync ─────────────────────────────

    /// A stranger syncs ONCE at hour 113; the player syncs once at hour 153.
    /// The outcome differs from the untouched run (scenario A): the influence
    /// remains. What this test pins is that repeats are useless — one outside
    /// sync is byte-for-byte equal to six, so the influence cannot grow back
    /// into several calls' worth unnoticed. How lethal the remaining single
    /// call can be is shown by the separate test in section 6.
    function test_OneOutsideSyncEqualsSix_RepeatsAreUseless() public {
        uint256 snap = vm.snapshotState();
        Game memory untouched = _scenarioA();
        vm.revertToState(snap);

        _warpHours(113);
        vm.prank(stranger);
        harness.sync(player);
        _warpHours(153);
        harness.sync(player);
        Game memory touched = _game();

        assertEq(uint256(untouched.diedAtHour), 134, "untouched: hour 134");
        assertTrue(touched.finished, "touched: dead by hour 153");
        assertEq(uint256(touched.diedAtHour), 135, "touched: hour 135, one later than untouched");
        assertTrue(keccak256(abi.encode(touched)) != keccak256(abi.encode(untouched)), "one outside sync does change the outcome");

        // And it is exactly what six outside syncs produce: repeats add nothing.
        vm.revertToState(snap);
        Game memory six = _scenarioB();
        assertEq(abi.encode(touched), abi.encode(six), "one outside sync == six outside syncs");
    }

    // ── 6. the open hole: one outside sync at a chosen hour is lethal ────────

    /// Second stand, values the game itself produces: hp 50 (what startGame
    /// gives), power 50, 3 observers, 2 rescuers, empty lab, word issued,
    /// 12 covered epochs, started at BASE.
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

    /// OPEN VULNERABILITY — this is not permitted behaviour. The decision on a
    /// real repair has not been taken.
    ///
    /// One free call by an outsider harms the player in EVERY pair checked, and
    /// in most of them it takes the whole run away. The reviewer swept a grid of
    /// 30 pairs (absence / hour of the player's own sync) on this stand with
    /// this word: in 17 of 30 the run is alive without the call and dead with
    /// one; in the other 13 the run dies either way, but EARLIER with the call.
    /// No pair was found where the outside call is harmless.
    ///
    /// The two pairs below are typical representatives, not exceptions. The
    /// player would never choose hour 20 (or 60) for an interaction; the
    /// attacker chooses exactly that, because a portal is born at hWalkEnd, the
    /// hour of the call. Three portals that appeared ahead of schedule have time
    /// to collapse, and every collapse costs HP.
    ///
    /// The concrete death hour depends on the epoch's word: the word decides
    /// the types of the portals that drop and, through them, the hours at which
    /// they collapse. That is why the stand pins the word explicitly; do not
    /// change it without re-measuring the numbers.
    ///
    /// This test exists so the hole is visible in the code and not only in a
    /// conversation. When it is truly repaired, this test is expected to fail,
    /// and that failure is the signal to rewrite it.
    ///
    /// Each case asserts BOTH outcomes separately, so the test shows what
    /// exactly changed: without the call the run is alive; with one call it is
    /// finished, at the stated hour.
    function _outsideCallKills(uint256 outsideHour, uint256 finalHour, uint32 deathHour, uint8 openAtDeath) internal {
        _seedLethalStand();
        uint256 snap = vm.snapshotState();

        // No interference: the player syncs once at finalHour.
        _warpHours(finalHour);
        harness.sync(player);
        Game memory clean = _game();
        assertFalse(clean.finished, "no outside call: run is not over");
        assertEq(uint256(clean.openPortals), 3, "no outside call: 3 portals open");
        assertEq(uint256(clean.hp), 50, "no outside call: hp untouched");
        assertEq(uint256(clean.hoursElapsed), finalHour, "no outside call: hours lived");

        // One outside call at outsideHour, then the player at finalHour.
        vm.revertToState(snap);
        _warpHours(outsideHour);
        vm.prank(stranger);
        harness.sync(player);
        _warpHours(finalHour);
        harness.sync(player);
        Game memory hit = _game();
        assertTrue(hit.finished, "one outside call: run is over");
        assertEq(uint256(hit.diedAtHour), uint256(deathHour), "one outside call: death hour");
        assertEq(uint256(hit.hp), 0, "one outside call: hp");
        assertEq(uint256(hit.openPortals), uint256(openAtDeath), "one outside call: portals open at death");
    }

    function test_OPEN_HOLE_OneOutsideSyncAtHour20KillsRunThatWouldSurvive() public {
        _outsideCallKills(20, 60, 50, 0);
    }

    function test_OPEN_HOLE_OneOutsideSyncAtHour60KillsRunThatWouldSurvive() public {
        _outsideCallKills(60, 120, 89, 1);
    }
}
