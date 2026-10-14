// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {Game, Portal, PortalType, PortalStatus, Action, Refusal} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title SurveyTest — twelve groups covering survey and knowledge decay
/// (ticket 1.7, SPEC §3.1, §6). State is prepared through `PortalLabHarness`
/// and driven through `harness.act(SendObserver)` / `harness.sync`, so each test
/// exercises the real flow. Structs are built fresh by helpers (never assigned
/// by copy — CLAUDE.md rule).
///
/// The RNG is the stub `RandomStub` (keccak of player + nonce + salt), so exact
/// values are not asserted; tests check ranges, determinism, independence and
/// the collapse-to-point / narrow invariants. `DefaultConfig`:
/// rangeWidenPerHour 1.
contract SurveyTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15;

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Active game at BASE: hp 100, power 100, full crew, one open portal,
    /// rngNonce 0.
    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    /// @dev Open, unsurveyed portal snapshotted at BASE, long-lived so it does
    /// not collapse in these windows. Ranges are left zero for the caller to set.
    function _baseMem() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1000;
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

    function _warpHours(uint40 h) internal {
        vm.warp(BASE + h * SPH);
    }

    /// @dev Two-phase survey (SPEC §6.3): commit + reveal in one step. With no
    /// time passing between them the reveal always applies (never cancels).
    function _surveyAndReveal(uint8 slot) internal {
        harness.act(slot, Action.SendObserver);
        harness.reveal(player);
    }

    // ── Group 1: Precise survey collapses the ranges to a point ───────────────

    function test_PreciseSurvey_ExactAndCollapsed() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived; // surveyPrecise = true
        p.energyLo = 20;
        p.energyHi = 60;
        p.stabilityLo = 40;
        p.stabilityHi = 90;
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        _write(_game(), p);

        _surveyAndReveal(0);

        Portal memory a = _portal_(0);
        assertTrue(a.surveyed, "surveyed");
        assertFalse(a.surveyPending, "no pending");
        // Values inside their ranges.
        assertTrue(a.energy >= 20 && a.energy <= 60, "energy in range");
        assertTrue(a.stability >= 40 && a.stability <= 90, "stability in range");
        assertTrue(a.creatures >= 1 && a.creatures <= 4, "creatures in range");
        // Ranges collapsed to the exact value.
        assertEq(a.energyLo, a.energy);
        assertEq(a.energyHi, a.energy);
        assertEq(a.stabilityLo, a.stability);
        assertEq(a.stabilityHi, a.stability);
        assertEq(a.creaturesLo, a.creatures);
        assertEq(a.creaturesHi, a.creatures);
    }

    // ── Group 2: The stub is deterministic ────────────────────────────────────

    /// @dev Survey a wide-range portal once on the shared harness and return the
    /// drawn values. The `nonce` argument seeds `Game.rngNonce` as before, but the
    /// survey VALUE now derives from the source's word, not rngNonce (SPEC §6.3):
    /// successive calls differ because the DeterministicSource advances its own
    /// nonce per request, giving each survey a fresh word.
    function _surveyOnce(uint32 nonce) internal returns (uint8 e, uint8 s, uint8 cr) {
        Game memory g = _game();
        g.rngNonce = nonce;
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived;
        p.energyLo = 0;
        p.energyHi = 100;
        p.stabilityLo = 0;
        p.stabilityHi = 100;
        p.creaturesLo = 0;
        p.creaturesHi = 10;
        _write(g, p);
        _surveyAndReveal(0);
        Portal memory a = _portal_(0);
        return (a.energy, a.stability, a.creatures);
    }

    /// @dev Survey a wide-range portal for `who` on a FRESH harness (so the
    /// source's nonce starts from zero again). Lets the determinism test prove the
    /// outcome is a reproducible function of (player, request order), replacing the
    /// old rngNonce-controlled determinism which no longer drives the draw.
    function _surveyFresh(address who) internal returns (uint8 e, uint8 s, uint8 cr) {
        PortalLabHarness h = new PortalLabHarness();
        Game memory g = _game();
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived;
        p.energyLo = 0;
        p.energyHi = 100;
        p.stabilityLo = 0;
        p.stabilityHi = 100;
        p.creaturesLo = 0;
        p.creaturesHi = 10;
        h.setGame(who, g);
        h.setPortal(who, 0, p);
        vm.prank(who);
        h.act(0, Action.SendObserver);
        h.reveal(who);
        Portal memory a = h.getPortals(who)[0];
        return (a.energy, a.stability, a.creatures);
    }

    function test_Deterministic() public {
        // Determinism now comes from the word (keccak(player, sourceNonce)), not
        // from rngNonce. Two FRESH sources for the same player reproduce the same
        // first word, hence the same survey; a different player differs.
        (uint8 e1, uint8 s1, uint8 c1) = _surveyFresh(player);
        (uint8 e2, uint8 s2, uint8 c2) = _surveyFresh(player);
        assertEq(e1, e2, "energy same");
        assertEq(s1, s2, "stability same");
        assertEq(c1, c2, "creatures same");

        (uint8 e3, uint8 s3, uint8 c3) = _surveyFresh(address(0xD1FF)); // different player → different
        assertTrue(e1 != e3 || s1 != s3 || c1 != c3, "different player differs");
    }

    function test_NonceAdvancesOnSurvey() public {
        Game memory g = _game();
        Portal memory p = _baseMem();
        p.energyLo = 0; p.energyHi = 100;
        p.stabilityLo = 0; p.stabilityHi = 100;
        p.creaturesLo = 0; p.creaturesHi = 10;
        _write(g, p);
        uint32 before = _game_().rngNonce;
        _surveyAndReveal(0);
        assertGt(_game_().rngNonce, before, "rngNonce must advance on a survey");
    }

    function test_TwoSurveysInOneGameDiffer() public {
        Game memory g = _game();
        g.openPortals = 2;
        Portal memory p0 = _baseMem();
        p0.energyLo = 0; p0.energyHi = 100;
        p0.stabilityLo = 0; p0.stabilityHi = 100;
        p0.creaturesLo = 0; p0.creaturesHi = 10;
        Portal memory p1 = _baseMem();
        p1.energyLo = 0; p1.energyHi = 100;
        p1.stabilityLo = 0; p1.stabilityHi = 100;
        p1.creaturesLo = 0; p1.creaturesHi = 10;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p0);
        harness.setPortal(player, 1, p1);
        _surveyAndReveal(0);
        _surveyAndReveal(1);
        Portal memory a = _portal_(0);
        Portal memory b = _portal_(1);
        assertTrue(a.energy != b.energy || a.stability != b.stability || a.creatures != b.creatures,
            "identical draws mean the nonce did not advance");
    }

    // ── Group 3: Salt makes the parameters independent ────────────────────────

    function test_Independence_EnergyVsStability() public {
        // Same wide range for energy and stability; without the per-parameter
        // salt they would draw from the same word and always coincide.
        uint256 differ = 0;
        for (uint32 i = 0; i < 50; i++) {
            (uint8 e, uint8 s,) = _surveyOnce(i);
            if (e != s) differ += 1;
        }
        // Expected ~49.5/50 differ; 40 leaves a huge margin while still failing
        // decisively if the salt were dropped (then energy == stability always).
        assertGe(differ, 40, "salt: energy and stability must not always coincide");
    }

    // ── Group 4: Boundaries of inRange ────────────────────────────────────────

    function test_Boundary_SinglePointRange() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived;
        p.energyLo = 42;
        p.energyHi = 42; // lo == hi → exactly 42
        p.stabilityLo = 7;
        p.stabilityHi = 7;
        p.creaturesLo = 3;
        p.creaturesHi = 3;
        _write(_game(), p);

        _surveyAndReveal(0);
        Portal memory a = _portal_(0);
        assertEq(a.energy, 42);
        assertEq(a.stability, 7);
        assertEq(a.creatures, 3);
    }

    function test_Boundary_FullRangeHasSpread() public {
        // 0..100 over 50 draws yields at least five distinct energy values.
        uint8[101] memory seen;
        uint256 distinct = 0;
        for (uint32 i = 0; i < 50; i++) {
            (uint8 e,,) = _surveyOnce(i);
            if (seen[e] == 0) {
                seen[e] = 1;
                distinct += 1;
            }
        }
        assertGe(distinct, 5, "full range must spread");
    }

    // ── Group 5: Deaf portal, first pass only narrows ─────────────────────────

    function _deafWide() internal pure returns (Portal memory p) {
        p = _baseMem();
        p.portalType = PortalType.Deaf; // surveyPrecise = false
        p.energyLo = 20;
        p.energyHi = 100; // width 80
        p.stabilityLo = 10;
        p.stabilityHi = 90; // width 80
        p.creaturesLo = 0;
        p.creaturesHi = 4; // width 4
    }

    function test_DeafFirstPass_NarrowsOnly() public {
        Portal memory p = _deafWide();
        _write(_game(), p);

        _surveyAndReveal(0);

        Portal memory a = _portal_(0);
        assertFalse(a.surveyed, "still unsurveyed");
        assertTrue(a.narrowedOnce, "narrowedOnce set by the first pass");
        // Each range strictly narrower and inside the old one.
        assertTrue(a.energyLo >= 20 && a.energyHi <= 100, "energy inside old");
        assertLt(a.energyHi - a.energyLo, 80, "energy narrower");
        assertTrue(a.stabilityLo >= 10 && a.stabilityHi <= 90, "stability inside old");
        assertLt(a.stabilityHi - a.stabilityLo, 80, "stability narrower");
        assertTrue(a.creaturesLo >= 0 && a.creaturesHi <= 4, "creatures inside old");
        assertLt(a.creaturesHi - a.creaturesLo, 4, "creatures narrower");
    }

    // ── Group 6: Deaf portal, second survey reads exact ───────────────────────

    function test_DeafNarrowsToPrecise() public {
        _write(_game(), _deafWide());

        _surveyAndReveal(0); // first pass: narrows, marks the portal
        Portal memory n = _portal_(0);
        assertTrue(n.narrowedOnce, "flag set");
        assertFalse(n.surveyed, "not surveyed yet");

        harness.act(0, Action.RecallObserver);
        _surveyAndReveal(0); // second pass: exact

        Portal memory a = _portal_(0);
        assertTrue(a.surveyed, "now surveyed");
        assertTrue(a.creaturesKnown, "creatures known");
        assertTrue(a.energy >= n.energyLo && a.energy <= n.energyHi, "energy inside narrowed range");
        assertTrue(a.stability >= n.stabilityLo && a.stability <= n.stabilityHi, "stability inside narrowed range");
        assertTrue(a.creatures >= n.creaturesLo && a.creatures <= n.creaturesHi, "creatures inside narrowed range");
        assertEq(a.energyLo, a.energy);
        assertEq(a.energyHi, a.energy);
        assertEq(a.stabilityLo, a.stability);
        assertEq(a.stabilityHi, a.stability);
        assertEq(a.creaturesLo, a.creatures);
        assertEq(a.creaturesHi, a.creatures);
    }

    function test_DeafWithFlag_WideRangesReadExact() public {
        Portal memory p = _deafWide(); // widths 80 / 80
        p.narrowedOnce = true;
        _write(_game(), p);

        _surveyAndReveal(0);

        Portal memory a = _portal_(0);
        assertTrue(a.surveyed, "surveyed on the next survey despite wide ranges");
        assertEq(a.energyLo, a.energy);
        assertEq(a.energyHi, a.energy);
        assertTrue(a.energy >= 20 && a.energy <= 100, "energy in range");
    }

    // ── Group 7: Deaf portal still needs a second pass ────────────────────────

    function test_DeafStillNeedsSecondPass() public {
        Portal memory p = _deafWide();
        _write(_game(), p);

        _surveyAndReveal(0); // narrows only, surveyed stays false

        // Stabilize is still refused: the portal is not surveyed yet.
        assertEq(uint8(harness.canAct(player, 0, Action.Stabilize)), uint8(Refusal.NotSurveyed));
    }

    // ── Group 8: Ranges widen with time ───────────────────────────────────────

    function test_RangesWidenWithTime() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived;
        p.energyLo = 40;
        p.energyHi = 60;
        p.stabilityLo = 40;
        p.stabilityHi = 60;
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        _write(_game(), p);

        _warpHours(10); // widen by rangeWidenPerHour(1) * 10 = 10 each bound
        harness.sync(player);
        Portal memory a = _portal_(0);
        assertEq(a.energyLo, 30, "energyLo 40-10");
        assertEq(a.energyHi, 70, "energyHi 60+10");
        assertEq(a.stabilityLo, 30, "stabilityLo 40-10");
        assertEq(a.stabilityHi, 70, "stabilityHi 60+10");

        _warpHours(100); // total 100 h from BASE → clamps to 0..100
        harness.sync(player);
        Portal memory b = _portal_(0);
        assertEq(b.energyLo, 0, "energyLo floors at 0");
        assertEq(b.energyHi, 100, "energyHi caps at 100");
        assertEq(b.stabilityLo, 0, "stabilityLo floors at 0");
        assertEq(b.stabilityHi, 100, "stabilityHi caps at 100");
    }

    // ── Group 9: Creatures range never widens ─────────────────────────────────

    function test_CreaturesRangeNeverWidens() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived;
        p.energyLo = 40;
        p.energyHi = 60;
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        _write(_game(), p);

        _warpHours(500);
        harness.sync(player);
        Portal memory a = _portal_(0);
        assertEq(a.creaturesLo, 1, "creaturesLo unchanged");
        assertEq(a.creaturesHi, 4, "creaturesHi unchanged");
    }

    // ── Group 10: A surveyed portal does not widen ────────────────────────────

    function test_SurveyedPortalDoesNotWiden() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived; // degrade 2/h
        p.surveyed = true;
        p.stability = 80;
        p.energy = 50;
        p.energyLo = 50;
        p.energyHi = 50; // exact, as survey would leave them
        p.creatures = 3;
        _write(_game(), p);

        _warpHours(10);
        harness.sync(player);
        Portal memory a = _portal_(0);
        assertEq(a.energyLo, 50, "energyLo stays exact");
        assertEq(a.energyHi, 50, "energyHi stays exact");
        assertEq(a.stability, 60, "stability still degrades: 80 - 2*10");
    }

    // ── Group 11: Widening does not change the blind-close penalty ─────────────

    function test_BlindCloseUnaffectedByWidening() public {
        // Now: unsurveyed portal, creatures 1..4, closable by time.
        Portal memory p0 = _baseMem();
        p0.portalType = PortalType.LongLived;
        p0.creaturesLo = 1;
        p0.creaturesHi = 4;
        p0.hoursToCollapse = 5; // <= closeHoursAtMost (6)
        // Births at maturity during the 100 hours below would otherwise drain the
        // default 100 HP and end the game; a durable lab keeps the close possible.
        Game memory durable = _game();
        durable.hp = 60_000;
        _write(durable, p0);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalClosed(player, 0, 4, 40, 0); // deaths creaturesHi=4, hpLost 10*4=40
        harness.act(0, Action.Close);

        // After 100 hours of widening the upper bound stays at 4 (creatures fixed).
        Portal memory p1 = _baseMem();
        p1.portalType = PortalType.LongLived;
        p1.creaturesLo = 1;
        p1.creaturesHi = 4;
        p1.hoursToCollapse = 105; // survives 100 h, then 5 <= 6 → closable
        _write(durable, p1);

        _warpHours(100);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalClosed(player, 0, 4, 40, 100);
        harness.act(0, Action.Close);
    }

    // ── Group 12: PortalSurveyed event carries the right `precise` ─────────────

    function test_Event_PortalSurveyed_Precise() public {
        Portal memory p = _baseMem();
        p.portalType = PortalType.LongLived; // precise
        p.energyLo = 20;
        p.energyHi = 60;
        p.stabilityLo = 40;
        p.stabilityHi = 90;
        p.creaturesLo = 1;
        p.creaturesHi = 4;
        _write(_game(), p);

        // PortalSurveyed fires in the REVEAL phase (SPEC §6.3), so expect it
        // around `reveal`, not the commit.
        harness.act(0, Action.SendObserver);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalSurveyed(player, 0, true, 0);
        harness.reveal(player);
    }

    function test_Event_PortalSurveyed_Narrowed() public {
        Portal memory p = _deafWide(); // deaf, wide → only narrows
        _write(_game(), p);

        harness.act(0, Action.SendObserver);
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalSurveyed(player, 0, false, 0);
        harness.reveal(player);
    }
}
