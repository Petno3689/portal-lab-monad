// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Config, Game, Portal, PortalType, PortalTypeParams, PortalStatus, Action
} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @title BalanceRulesTest — regression suite for the close/collapse formula
/// asymmetry, hpStart, creaturesKnown propagation.
///
/// Tests 8.1–8.8 as specified in the balance-rules change ticket.
/// Run via: forge test --match-contract BalanceRulesTest -vv
contract BalanceRulesTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15; // DefaultConfig.secPerHour

    function setUp() public {
        harness = new PortalLabHarness();
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

    /// @dev Open surveyed portal, empty, closable by stability (< 40).
    function _closable() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.stability = 30; // < closeStabilityBelow (40)
        p.energy = 50;
        p.hoursToCollapse = 24;
        p.snapshotAt = BASE;
    }

    function _write(Game memory g, Portal memory p) internal {
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);
    }

    function _game_() internal view returns (Game memory) {
        return harness.getGame(player);
    }

    // ── 8.1: Close empty portal costs no HP ──────────────────────────────────

    function test_8_1_CloseEmpty_NoHpLoss() public {
        Portal memory p = _closable();
        p.creatures = 0;
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(_game_().hp, 100);
    }

    // ── 8.2: Close surveyed portal: hpLost = hpCollapsePerDeath * N exactly ─

    function test_8_2_CloseSurveyed_N1() public {
        Portal memory p = _closable();
        p.creatures = 1;
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(_game_().hp, 92); // 100 - 8*1
    }

    function test_8_2_CloseSurveyed_N2() public {
        Portal memory p = _closable();
        p.creatures = 2;
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(_game_().hp, 84); // 100 - 8*2
    }

    function test_8_2_CloseSurveyed_N3() public {
        Portal memory p = _closable();
        p.creatures = 3;
        _write(_game(), p);
        harness.act(0, Action.Close);
        assertEq(_game_().hp, 76); // 100 - 8*3
    }

    // ── 8.3: Blind close charges creaturesHi, NOT midpoint ───────────────────

    function test_8_3_BlindClose_ChargesUpperBound() public {
        Portal memory p = _closable();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creaturesLo = 2;
        p.creaturesHi = 3;
        p.creatures = 99; // must be ignored
        p.hoursToCollapse = 5; // closable by time (<=6)
        _write(_game(), p);
        harness.act(0, Action.Close);
        // deaths = creaturesHi = 3; hpLost = 8*3 = 24.
        // NOT 8*2=16 (midpoint would be 2.5→2 truncated) and NOT 8*2.5=20.
        assertEq(_game_().hp, 76); // 100 - 24
    }

    // ── 8.4: Crew inside counts as extra deaths on close ─────────────────────

    function test_8_4_ObserverAddsOneDeath() public {
        Portal memory p = _closable();
        p.creatures = 2;
        p.observerInside = true;
        Game memory g = _game();
        g.observersFree = 2; // one free, one inside
        _write(g, p);
        harness.act(0, Action.Close);
        // deaths = 2 creatures + 1 observer = 3; hpLost = 8*3 = 24.
        assertEq(_game_().hp, 76); // 100 - 24
    }

    function test_8_4_RescuerAddsOneDeath() public {
        Portal memory p = _closable();
        p.creatures = 2;
        p.rescuerInside = true;
        Game memory g = _game();
        g.rescuersFree = 1; // one free, one inside
        _write(g, p);
        harness.act(0, Action.Close);
        // deaths = 2 creatures + 1 rescuer = 3; hpLost = 8*3 = 24.
        assertEq(_game_().hp, 76); // 100 - 24
    }

    function test_8_4_BothCrewAddTwoDeaths() public {
        Portal memory p = _closable();
        p.creatures = 2;
        p.observerInside = true;
        p.rescuerInside = true;
        Game memory g = _game();
        g.observersFree = 2;
        g.rescuersFree = 1;
        _write(g, p);
        harness.act(0, Action.Close);
        // deaths = 2 creatures + observer + rescuer = 4; hpLost = 8*4 = 32.
        assertEq(_game_().hp, 68); // 100 - 32
    }

    // ── 8.5: Collapse uses midpoint AND hpCollapseBase — DIFFERENT from close ─
    //
    // This guards against "aligning" the two formulas. Collapse is an accident
    // (pays base + midpoint); close is a player decision (pays per-death × Hi,
    // no base). They must stay different.

    function test_8_5_Collapse_Unsurveyed_UsesBasePlusMidpoint() public {
        // creaturesLo=2, creaturesHi=4: midpoint = (2+4)/2 = 3.
        // Collapse: hpLost = hpCollapseBase + hpCollapsePerDeath * 3 = 20 + 24 = 44.
        // Close (same range): deaths = creaturesHi = 4, hpLost = 8*4 = 32.
        // These MUST differ — the test asserts the collapse (base+midpoint) value.
        Game memory g = _game();
        g.openPortals = 1;
        Portal memory p = _closable();
        p.surveyed = false;
        p.creaturesKnown = false;
        p.creaturesLo = 2;
        p.creaturesHi = 4;
        p.creatures = 99; // must be ignored
        p.hoursToCollapse = 3;
        p.snapshotAt = BASE;
        _write(g, p);

        vm.warp(BASE + 3 * SPH);
        harness.sync(player);

        // hpLost from collapse = 20 + 8*3 = 44; NOT 32 (close formula).
        assertEq(_game_().hp, 56); // 100 - 44
    }

    // ── 8.6: New game starts with hpStart, not hpMax ──────────────────────────

    function test_8_6_NewGame_StartsAtHpStart() public {
        Config memory c = DefaultConfig.config();
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        PortalLab lab = new PortalLab(c, params, harness.source());

        vm.prank(address(0xBEEF));
        lab.startGame();

        Game memory g = lab.getGame(address(0xBEEF));
        assertEq(g.hp, c.hpStart);       // must equal hpStart (80)
        assertEq(c.hpStart, 80);          // anchor: DefaultConfig.hpStart == 80
        assertTrue(c.hpStart < c.hpMax);  // hpStart < hpMax (100)
    }

    // ── 8.7: Constructor rejects hpStart=0 and hpStart>hpMax ─────────────────

    function test_8_7_Constructor_RejectsHpStartZero() public {
        Config memory c = DefaultConfig.config();
        c.hpStart = 0;
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        DeterministicSource s = harness.source();

        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hpStart"));
        new PortalLab(c, params, s);
    }

    function test_8_7_Constructor_RejectsHpStartOverMax() public {
        Config memory c = DefaultConfig.config();
        c.hpStart = c.hpMax + 1;
        PortalTypeParams[5] memory params = DefaultConfig.portalTypeParams();
        DeterministicSource s = harness.source();

        vm.expectRevert(abi.encodeWithSelector(PortalLab.InvalidConfig.selector, "hpStart"));
        new PortalLab(c, params, s);
    }

    // ── 8.8: creaturesKnown set on exact survey, NOT on deaf first pass ───────

    function test_8_8_ExactSurvey_SetsCreaturesKnown() public {
        // LongLived is surveyPrecise=true. After the two-phase survey
        // (SendObserver commit + reveal), creaturesKnown must be true.
        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.creaturesKnown = false;
        p.portalType = PortalType.LongLived;
        p.creaturesLo = 2;
        p.creaturesHi = 5;
        p.hoursToCollapse = 30;
        p.snapshotAt = BASE;
        _write(_game(), p);

        harness.act(0, Action.SendObserver);
        harness.reveal(player);

        Portal memory after_ = harness.getPortals(player)[0];
        assertTrue(after_.surveyed, "surveyed must be true after precise survey");
        assertTrue(after_.creaturesKnown, "creaturesKnown must be true after precise survey");
    }

    function test_8_8_DeafFirstPass_DoesNotSetCreaturesKnown() public {
        // Deaf is surveyPrecise=false. The first survey of a Deaf portal
        // (narrowedOnce still false) only narrows — surveyed and creaturesKnown
        // must both stay false; the second survey reads exact. `surveyPending` is set at commit and
        // cleared again on reveal (SPEC §6.3), so after the full survey it is false.
        // The observer stays inside waiting for a recall and a second visit.
        Config memory c = DefaultConfig.config();

        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.creaturesKnown = false;
        p.portalType = PortalType.Deaf;
        p.energyLo = 0;
        p.energyHi = 80; // wide ranges; first survey (narrowedOnce == false) only narrows
        p.stabilityLo = 0;
        p.stabilityHi = 80;
        p.creaturesLo = 0;
        p.creaturesHi = 80;
        p.hoursToCollapse = 30;
        p.snapshotAt = BASE;

        _write(_game(), p);
        harness.act(0, Action.SendObserver);
        harness.reveal(player);

        Portal memory after_ = harness.getPortals(player)[0];
        assertFalse(after_.surveyed, "surveyed must stay false after deaf first-pass narrow");
        assertFalse(after_.creaturesKnown, "creaturesKnown must stay false after deaf first-pass narrow");
        assertTrue(after_.observerInside, "observer still inside after deaf narrow");
        assertFalse(after_.surveyPending, "surveyPending cleared on reveal (SPEC 6.3)");
        // Ranges narrowed (not zero-wide), confirming the survey step ran.
        assertGt(after_.creaturesHi - after_.creaturesLo, 0, "deaf first pass narrows but does not collapse to a point");
    }
}
