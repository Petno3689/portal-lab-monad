// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Portal, PortalType, PortalTypeParams, PortalStatus, Action, SPAWN_DEBT_MAX} from "../src/PortalLabTypes.sol";
import {TimeLib} from "../src/TimeLib.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @dev Test-only harness that also exposes `TimeLib.spawnPressure` so the
/// closed-form pressure can be compared against a reference loop (group 2).
contract SpawnHarness is PortalLabHarness {
    function spawnPressure(uint256 a, uint256 b) external pure returns (uint256) {
        return TimeLib.spawnPressure(a, b, DefaultConfig.config());
    }
}

/// @title SpawnTest — sixteen groups covering pressure and spawns (ticket 1.8,
/// SPEC §4.6, §5.5, §7). State is prepared through `SpawnHarness`; structs are
/// built fresh by helpers (never assigned by copy — CLAUDE.md rule).
///
/// `DefaultConfig` (all placeholders): secPerHour 15, MAX_OPEN_PORTALS 12,
/// maxSpawnsPerTx 3, basePressurePerHour 1000, pressureRampPerHour 2,
/// spawnCostUnits 10_000, closePressureBonus 2500, hpMax 100,
/// hpOverflowPerHour 5. Pressure over game hours [a,b) is the closed form
///   base*(b-a) + ramp*((a+b-1)*(b-a))/2.
/// Handy values used below:
///   P(0,10)  = 10_000 + 2*(9*10)/2      = 10_090
///   P(0,100) = 100_000 + 2*(99*100)/2   = 109_900
///   P(0,108) = 108_000 + 2*(107*108)/2  = 119_556  (< 120_000)
///   P(0,109) = 109_000 + 2*(108*109)/2  = 120_772  (>= 120_000)
///   444 + P(0,108) = 120_000 exactly
contract SpawnTest is Test {
    SpawnHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15;

    function setUp() public {
        harness = new SpawnHarness();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Active game at BASE: hp 100, power 100, full crew, empty lab.
    function _g() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
    }

    /// @dev Open, surveyed Flash portal snapshotted at BASE.
    function _p() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.stability = 100;
        p.energy = 50;
        p.hoursToCollapse = 1000;
        p.snapshotAt = BASE;
    }

    function _warpHours(uint40 h) internal {
        vm.warp(BASE + h * SPH);
    }

    function _game_() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    function _portal_(uint8 slot) internal view returns (Portal memory) {
        return harness.getPortals(player)[slot];
    }

    // ── Group 1: The first portal appears on time ─────────────────────────────

    function test_FirstPortalAppearsOnTime() public {
        harness.setGame(player, _g()); // empty lab, spawnDebt 0

        // P(0,10) = 10_000 + 2*45 = 10_090 >= spawnCostUnits(10_000) and < 20_000 → exactly 1.
        _warpHours(10);
        vm.expectEmit(true, true, false, false); // check player + slot, ignore data
        emit PortalLab.PortalSpawned(player, 0, PortalType.Flash, 0, 10);
        harness.sync(player);

        assertEq(_game_().openPortals, 1, "one portal");
        assertEq(_game_().spawnCount, 1, "one spawn counted");
        assertEq(uint8(_portal_(0).status), uint8(PortalStatus.Open), "slot 0 open");
        assertEq(_game_().spawnDebt, 90, "10_090 - 10_000 spent");
    }

    // ── Group 2: The closed form equals a reference loop ──────────────────────

    function test_ClosedFormMatchesLoop() public view {
        // A per-hour loop is the reference (allowed in a test); the contract must
        // never loop over hours (SPEC §7).
        uint256 loopSum = 0;
        for (uint256 h = 0; h < 100; h++) {
            loopSum += uint256(1000) + uint256(2) * h; // base + ramp*h
        }
        assertEq(harness.spawnPressure(0, 100), loopSum, "P(0,100) closed form");
        assertEq(harness.spawnPressure(0, 100), 109_900, "P(0,100) literal"); // 100_000 + 2*4_950

        // An offset window too, to catch an `a`-independent formula.
        uint256 loopOff = 0;
        for (uint256 h = 50; h < 150; h++) {
            loopOff += uint256(1000) + uint256(2) * h;
        }
        assertEq(harness.spawnPressure(50, 150), loopOff, "P(50,150) closed form");
    }

    // ── Group 3: Difficulty ramps up ──────────────────────────────────────────

    function test_DifficultyRampsUp() public view {
        uint256 firstHundred = harness.spawnPressure(0, 100); // 109_900
        uint256 secondHundred = harness.spawnPressure(100, 200); // 129_900
        assertGt(secondHundred, firstHundred, "later hours accrue more pressure");
    }

    // ── Group 4: Portals are born at maturity, not at the call ───────────────

    /// One call after 25 hours: the k-th portal is born at the first hour the
    /// pressure reaches k * spawnCostUnits — hours 10 and 20 — not at hour 25,
    /// and there is no per-call cap. P(0,10) = 10_090, P(0,20) = 20_380,
    /// P(0,25) = 25_600, so 5_600 is left over.
    function test_BirthsHappenAtMaturity() public {
        harness.setGame(player, _g()); // empty lab, spawnDebt 0

        _warpHours(25);
        vm.recordLogs();
        harness.sync(player);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256[2] memory want = [uint256(10), 20];
        uint256 n;
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].topics[0] != PortalLab.PortalSpawned.selector) continue;
            (,, uint32 atHour) = abi.decode(logs[k].data, (PortalType, uint16, uint32));
            assertLt(n, 2, "only two portals matured");
            assertEq(uint256(atHour), want[n], "born at the hour its pressure matured");
            n += 1;
        }
        assertEq(n, 2, "two births");
        assertEq(_game_().spawnCount, 2, "two counted");
        assertEq(_game_().spawnDebt, 25_600 - 20_000, "the remainder stays in the debt");
    }

    /// The `>=` of the maturity rule, pinned at equality: 4_980 + P(0,5) = 4_980 +
    /// 5_020 = 10_000 exactly, so the portal is born at hour 5, not hour 6.
    /// The hour before stays below: 4_980 + P(0,4) = 4_980 + 4_012 = 8_992 < 10_000.
    /// (P(0,5) = 5_000 + 2*(4*5)/2 = 5_020; P(0,4) = 4_000 + 2*(3*4)/2 = 4_012.)
    function test_BirthAtExactMaturityBoundary() public {
        Game memory g = _g();
        g.spawnDebt = 4980;
        harness.setGame(player, g);

        _warpHours(8);
        harness.sync(player);
        assertEq(_game_().spawnCount, 1, "one birth");
        assertEq(_portal_(0).spawnedAtHour, 5, "born exactly when A(h) == spawnCostUnits");
    }

    // ── Group 5: A matured birth waits for a full lab to free a slot ──────────

    /// Twelve open, one portal's worth of debt already matured at hour 0. The
    /// birth waits for the first collapse (slot 0, hour 12) and happens AT that
    /// collapse; the next portal matures at hour 10 (10_000 + P(0,10) >= 20_000)
    /// but finds the lab full again and keeps waiting. HP: overflow 12 h * 5 =
    /// 60, the empty collapse 3, overflow again 3 h * 5 = 15 → 100 - 78 = 22.
    function test_MaturedBirthWaitsForFullLab() public {
        _fillTwelve(100, 10_000);
        Portal memory first = _p();
        first.hoursToCollapse = 12; // empty, surveyed: costs hpEmptyCollapse (3)
        harness.setPortal(player, 0, first);

        _warpHours(15);
        harness.sync(player);

        assertEq(_game_().spawnCount, 1, "exactly one birth: the lab filled again");
        assertEq(_portal_(0).spawnedAtHour, 12, "born at the collapse that freed the slot");
        assertEq(_portal_(0).id, 1, "the newborn took the freed slot");
        assertEq(_game_().openPortals, 12, "full again");
        // 10_000 + P(0,15) - 10_000 = P(0,15) = 15_000 + 2*(14*15)/2 = 15_210.
        assertEq(_game_().spawnDebt, 15_210, "the second portal's pressure keeps waiting");
        assertEq(_game_().hp, 22, "overflow, collapse, overflow");
    }
    // ── Group 6: The lab cap blocks spawns and spends nothing ─────────────────

    function _fillTwelve(uint16 hp, uint32 debt) internal {
        Game memory g = _g();
        g.hp = hp;
        g.openPortals = 12;
        g.spawnDebt = debt;
        harness.setGame(player, g);
        for (uint8 i = 0; i < 12; i++) {
            Portal memory p = _p();
            p.hoursToCollapse = 5000; // none collapse in the window
            harness.setPortal(player, i, p);
        }
    }

    function test_LabCapBlocksSpawns() public {
        _fillTwelve(100, 1_000_000); // plenty of pressure, but no free slot

        _warpHours(1); // short: overflow -5 HP, survives
        harness.sync(player);

        assertEq(_game_().openPortals, 12, "still full");
        assertEq(_game_().spawnCount, 0, "nothing spawned");
        // P(0,1) = 1000 accrues, but none is SPENT (no free slot).
        assertEq(_game_().spawnDebt, 1_000_000 + 1000, "pressure accrued, not spent");
    }

    // ── Group 7: A new portal's parameters ────────────────────────────────────

    function test_NewPortalParameters() public {
        harness.setGame(player, _g());

        _warpHours(10); // one portal into slot 0 at hour 10
        harness.sync(player);

        Portal memory a = _portal_(0);
        assertFalse(a.surveyed, "unsurveyed");
        assertFalse(a.surveyPending, "no pending survey");
        assertFalse(a.observerInside, "no observer");
        assertFalse(a.rescuerInside, "no rescuer");
        assertEq(uint8(a.status), uint8(PortalStatus.Open), "open");
        assertEq(a.spawnedAtHour, 10, "spawnedAtHour == current hour");
        assertEq(a.id, 1, "id incremented from 0");

        // Ranges are the type table verbatim; exact values are NOT rolled here.
        PortalTypeParams memory tp = DefaultConfig.portalTypeParams()[uint8(a.portalType)];
        assertEq(a.energyLo, tp.energyMin, "energyLo == type min");
        assertEq(a.energyHi, tp.energyMax, "energyHi == type max");
        assertEq(a.stabilityLo, tp.stabilityMin, "stabilityLo == type min");
        assertEq(a.stabilityHi, tp.stabilityMax, "stabilityHi == type max");
        assertEq(a.creaturesLo, tp.creaturesMin, "creaturesLo == type min");
        assertEq(a.creaturesHi, tp.creaturesMax, "creaturesHi == type max");
        assertTrue(a.hoursToCollapse >= tp.hoursMin && a.hoursToCollapse <= tp.hoursMax, "htc within type range");
        // Exact fields stay zero until survey.
        assertEq(a.energy, 0, "exact energy unset");
        assertEq(a.stability, 0, "exact stability unset");
        assertEq(a.creatures, 0, "exact creatures unset");
    }

    // ── Group 8: Portals in one call differ ───────────────────────────────────

    function _triple(Portal memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.portalType, p.hoursToCollapse, p.nameIndex));
    }

    function test_PortalsInOneCallDiffer() public {
        // Three births in ONE call with no collapse in between: the debt already
        // holds 3 * spawnCostUnits, so all three mature at the call's first hour.
        Game memory g = _g();
        g.spawnDebt = 30_000;
        harness.setGame(player, g);

        _warpHours(1);
        harness.sync(player);

        Portal memory a = _portal_(0);
        Portal memory b = _portal_(1);
        Portal memory c = _portal_(2);

        // Sequential ids prove three distinct rolls advanced the counter.
        assertEq(a.id, 1);
        assertEq(b.id, 2);
        assertEq(c.id, 3);
        // And the contents are not all identical (the roll counter moved).
        assertFalse(_triple(a) == _triple(b) && _triple(b) == _triple(c), "not all three identical");
    }

    // ── Group 9: Closing adds pressure ────────────────────────────────────────

    function test_ClosingAddsPressure() public {
        Game memory g = _g();
        g.openPortals = 1;
        g.spawnDebt = 8000;
        harness.setGame(player, g);

        Portal memory p = _p();
        p.stability = 30; // < closeStabilityBelow(40) → closable, surveyed
        p.creatures = 0; // empty close: no HP cost
        harness.setPortal(player, 0, p);

        // No time passes, so catch-up neither accrues nor spends pressure; only
        // the Close bonus moves spawnDebt.
        harness.act(0, Action.Close);
        assertEq(_game_().spawnDebt, 8000 + 2500, "grew by exactly closePressureBonus");
        assertEq(_game_().openPortals, 0, "portal closed");

        // The debt now holds a full portal (10_500 >= spawnCostUnits). It matured
        // at the close hour, so the next catch-up births it AT that hour, even
        // with no time passed: spawnedAtHour == the close hour (0).
        harness.sync(player);
        assertEq(_game_().openPortals, 1, "the matured portal is born at the close hour");
        assertEq(_game_().spawnCount, 1, "one birth");
        assertEq(_portal_(0).spawnedAtHour, 0, "born at the close hour");
        assertEq(_game_().spawnDebt, 500, "10_500 - 10_000 spent");

        // One game hour later only P(0,1) = 1_000 accrues: 1_500, not enough.
        _warpHours(1);
        harness.sync(player);
        assertEq(_game_().spawnCount, 1, "no second birth");
        assertEq(_game_().spawnDebt, 1_500, "500 + 1_000 accrued");
    }

    // ── Group 10: A collapse does NOT add pressure ────────────────────────────

    function test_CollapseDoesNotAddPressure() public {
        Game memory g = _g();
        g.openPortals = 1;
        harness.setGame(player, g); // spawnDebt 0

        Portal memory p = _p();
        p.creatures = 0; // empty collapse
        p.hoursToCollapse = 5; // collapses at hour 5
        harness.setPortal(player, 0, p);

        _warpHours(5);
        harness.sync(player);

        // Only time accrual, P(0,5) = 5000 + 2*(4*5)/2 = 5020. A Close would have
        // added closePressureBonus (2500) on top; a collapse must not.
        assertEq(_game_().spawnDebt, 5020, "collapse adds no close bonus");
        assertEq(_game_().openPortals, 0, "collapsed slot freed");
    }

    // ── Group 11: Long pause → deterministic overflow death ───────────────────

    function test_LongPauseOverflowDeath() public {
        harness.setGame(player, _g()); // empty lab, hp 100

        _warpHours(10_000);
        harness.sync(player);

        // The abandoned lab is walked event by event: portals are born at their
        // maturity hours (10, 20, 30, 39 — the fifth, due at 48, finds the run
        // already dead) and newborns collapse; the lethal collapse falls at hour
        // 48 under this harness word: collapses at hours 16, 47 and 48 cost
        // 36 + 28 + 36 = 100 hp, so hp reaches exactly 0 at the third. The types
        // and lifetimes of the newborns come from epochSeed(word, hour / epochHours);
        // the old analytic fill-and-overflow put death at 134.
        assertTrue(_game_().finished, "game over");
        assertEq(_game_().diedAtHour, 48, "death at the hour of the lethal collapse");
        assertLt(_game_().diedAtHour, 10_000, "far short of the pause");
        assertEq(_game_().hp, 0, "hp zeroed");
        assertEq(_game_().openPortals, 1, "portals open at death");
        assertEq(_game_().spawnCount, 4, "every portal that matured before death was born");
    }

    // ── Group 12: hFill is found exactly ──────────────────────────────────────
    //
    // The analytic fill hour now lives only BEYOND the pinned edge, where the
    // world cannot be walked (no word, no births) yet the abandoned lab still
    // overflows. Nothing is pinned here, so the whole window is beyond the edge.

    function test_FillHourIsExact() public {
        Game memory g = _g();
        g.hp = 60; // ceil(60/5) = 12 overflow hours to death
        harness.setGame(player, g);
        harness.setCoverage(player, harness.epochWordOf(player), 0); // nothing pinned

        _warpHours(200);
        harness.sync(player);

        // Hand-computed: needed 120_000, P(0,108)=119_556 < 120_000 <= 120_772
        // =P(0,109) → hFill = 109. diedAtHour = 109 + 12 = 121.
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 121, "hFill 109 + ceil(60/5) 12");
    }

    // ── Group 13: Gas — a long pause is not worse than twice a short one ───────

    function _setupTwo(address who, uint16 hp) internal {
        Game memory g = _g();
        g.hp = hp;
        g.openPortals = 2;
        harness.setGame(who, g);
        for (uint8 i = 0; i < 2; i++) {
            Portal memory p = _p();
            p.hoursToCollapse = 65_535; // survive either window
            harness.setPortal(who, i, p);
        }
    }

    function test_Gas_LongPauseIsNotWorse() public {
        address shortP = address(0x5401);
        address longP = address(0x1075);
        _setupTwo(shortP, 100);
        _setupTwo(longP, 100);

        // 30 h already accrues maxSpawnsPerTx portals (P(0,30) = 30_435 ≥ 3*cost
        // for the two free-slot budget), so both calls create the same number of
        // portals and the only extra cost the long pause pays is the binary
        // search — which is O(1) in the pause length.
        _warpHours(30);
        uint256 g0 = gasleft();
        harness.sync(shortP);
        uint256 usedShort = g0 - gasleft();

        _warpHours(60_000);
        uint256 g1 = gasleft();
        harness.sync(longP); // fills, overflows, dies — via binary search
        uint256 usedLong = g1 - gasleft();

        // The binary search (≤64 iterations) is O(1) in the pause length, so a
        // 6,000x longer pause must not even double the cost.
        assertLe(usedLong, usedShort * 2, "long pause is not O(hours)");
    }

    // ── Group 14: Pressure saturates, never overflowing uint32 ────────────────

    function test_PressureSaturates() public {
        // Full lab, no collapse in the window, hp enough for the overflow: nothing
        // is born or spent, so the debt just accrues and must saturate, not wrap.
        // 100 hp - 10 h * 5 overflow = 50 survives; P(0,10) = 10_090 > the 100 left.
        _fillTwelve(100, uint32(SPAWN_DEBT_MAX - 100));

        _warpHours(10);
        harness.sync(player);

        assertFalse(_game_().finished, "the lab survived the window");
        assertEq(_game_().spawnCount, 0, "no free slot: nothing born");
        assertEq(uint256(_game_().spawnDebt), SPAWN_DEBT_MAX, "saturated at SPAWN_DEBT_MAX");
    }

    // ── Group 15: `preview` matches `sync`, spawns included ────────────────────

    function _assertPreviewMatchesSync() internal {
        (Game memory gp, Portal[12] memory pp,) = harness.preview(player);
        harness.sync(player);
        Game memory gs = _game_();

        assertEq(gp.hp, gs.hp, "hp");
        assertEq(gp.openPortals, gs.openPortals, "openPortals");
        assertEq(uint256(gp.spawnDebt), uint256(gs.spawnDebt), "spawnDebt");
        assertEq(uint256(gp.spawnCount), uint256(gs.spawnCount), "spawnCount");
        assertEq(uint256(gp.rngNonce), uint256(gs.rngNonce), "rngNonce");
        assertTrue(gp.finished == gs.finished, "finished");
        assertEq(uint256(gp.diedAtHour), uint256(gs.diedAtHour), "diedAtHour");

        for (uint8 i = 0; i < 12; i++) {
            Portal memory ps = _portal_(i);
            assertEq(uint8(pp[i].status), uint8(ps.status), "status");
            assertEq(uint8(pp[i].portalType), uint8(ps.portalType), "portalType");
            assertEq(pp[i].id, ps.id, "id");
            assertEq(pp[i].nameIndex, ps.nameIndex, "nameIndex");
            assertEq(pp[i].hoursToCollapse, ps.hoursToCollapse, "htc");
            assertEq(uint256(pp[i].snapshotAt), uint256(ps.snapshotAt), "snapshotAt");
        }
    }

    function test_PreviewMatchesSync_NormalSpawn() public {
        harness.setGame(player, _g());
        _warpHours(10); // one spawn
        _assertPreviewMatchesSync();
    }

    function test_PreviewMatchesSync_LongPauseDeath() public {
        harness.setGame(player, _g());
        _warpHours(10_000); // fill → overflow death, three spawns
        _assertPreviewMatchesSync();
    }

    // ── Group 16: Exact boundary of fill hour predicate ───────────────────────

    /// This test pinpoints the exact boundary between ">= needed" and "> needed"
    /// in TimeLib._fillHour. At P(0,108) = 119_556 and spawnDebt = 444, the sum
    /// equals 120_000 (needed) exactly. Without this test, the predicate can be
    /// incorrectly weakened to "> needed" and all 178 tests still pass.
    function test_FillHourExactBoundary() public {
        Game memory g = _g();
        g.hp = 60; // ceil(60/5) = 12 overflow hours to death
        g.spawnDebt = 444;
        harness.setGame(player, g);
        harness.setCoverage(player, harness.epochWordOf(player), 0); // nothing pinned: beyond the edge

        _warpHours(200);
        harness.sync(player);

        // Exact: 444 + P(0,108) = 444 + 119_556 = 120_000 = needed.
        // hFill = 108, diedAtHour = 108 + 12 = 120.
        assertTrue(_game_().finished);
        assertEq(_game_().diedAtHour, 120, "hFill 108 + ceil(60/5) 12");
    }
}
