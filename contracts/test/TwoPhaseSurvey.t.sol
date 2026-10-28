// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Game, Portal, Pending, PortalType, PortalStatus, Action, Refusal, MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";

/// @title TwoPhaseSurveyTest — the two-phase survey machinery (Ticket 4.4).
/// @notice Covers the commit/reveal split, the one-deferred-action lock, the
/// delivery trust gate, the fee (under/over-pay), the cancellation-on-collapse
/// path, and the reveal-phase gas budget. The happy-path survey mechanics
/// themselves live in Survey.t.sol; this file is about the two-phase plumbing.
contract TwoPhaseSurveyTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1000;
    uint40 internal constant SPH = 15; // DefaultConfig.secPerHour

    // Accept refunds (overpay change) from the contract.
    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    /// @dev Open, unsurveyed, long-lived (precise) portal that will not collapse
    /// in these windows. Ranges zeroed for simplicity.
    function _unsurveyed() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1000;
    }

    function _write(Game memory g, Portal memory p) internal {
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);
    }

    function _portal(uint8 slot) internal view returns (Portal memory) {
        return harness.getPortals(player)[slot];
    }

    // ── Commit ──────────────────────────────────────────────────────────────────

    function test_Commit_RecordsDeferralAndSpendsUpFront() public {
        _write(_game(), _unsurveyed());

        harness.act(0, Action.SendObserver);

        Pending memory pend = harness.getPending(player);
        assertTrue(pend.active, "pending active");
        assertEq(uint8(pend.action), uint8(Action.SendObserver), "action");
        assertEq(pend.slot, 0, "slot");
        assertGt(pend.requestId, 0, "requestId assigned");

        Portal memory p = _portal(0);
        assertTrue(p.observerInside, "observer walked in at commit");
        assertTrue(p.surveyPending, "surveyPending set at commit");
        assertFalse(p.surveyed, "not surveyed until reveal");

        Game memory g = harness.getGame(player);
        assertEq(g.observersFree, 2, "observer taken from the pool");
        assertEq(g.power, 90, "power spent up front (100 - 10)");
    }

    // ── One-deferred-action lock ─────────────────────────────────────────────────

    function test_PendingLock_BlocksEveryOtherAction() public {
        Game memory g = _game();
        g.openPortals = 2;
        Portal memory p0 = _unsurveyed();
        Portal memory p1 = _unsurveyed();
        p1.surveyed = true; // so a bare action on it would otherwise be allowed
        p1.creaturesKnown = true;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p0);
        harness.setPortal(player, 1, p1);

        harness.act(0, Action.SendObserver); // commit — now locked

        vm.expectRevert(PortalLab.ActionPending.selector);
        harness.act(1, Action.ToggleQuestioned);

        // A second survey is likewise refused.
        vm.expectRevert(PortalLab.ActionPending.selector);
        harness.act(1, Action.SendObserver);
    }

    function test_Reveal_ReleasesLock() public {
        _write(_game(), _unsurveyed());
        harness.act(0, Action.SendObserver);
        harness.reveal(player);

        assertFalse(harness.getPending(player).active, "lock released after reveal");
        // A new action now goes through.
        harness.act(0, Action.RecallObserver);
        assertFalse(_portal(0).observerInside, "observer recalled after reveal");
    }

    // ── Delivery trust gate (SPEC §6.4) ──────────────────────────────────────────

    function test_Reveal_RejectsNonSourceCaller() public {
        _write(_game(), _unsurveyed());
        harness.act(0, Action.SendObserver);
        uint64 reqId = harness.getPending(player).requestId;

        // Anyone-but-the-source is rejected.
        vm.expectRevert(PortalLab.NotRandomSource.selector);
        harness.receiveWord(player, reqId, uint256(keccak256("evil")));
    }

    function test_Reveal_RejectsWrongRequestId() public {
        _write(_game(), _unsurveyed());
        harness.act(0, Action.SendObserver);
        uint64 reqId = harness.getPending(player).requestId;

        // Correct caller (the source) but a mismatched id.
        vm.prank(address(source));
        vm.expectRevert(PortalLab.UnknownRequest.selector);
        harness.receiveWord(player, reqId + 99, uint256(keccak256("w")));
    }

    // ── Fee (Ticket 4.4 §4.3) ────────────────────────────────────────────────────

    function test_Fee_UnderpayReverts() public {
        source.setFee(1 ether);
        _write(_game(), _unsurveyed());

        vm.expectRevert(abi.encodeWithSelector(PortalLab.InsufficientFee.selector, uint256(1 ether), uint256(1 ether - 1)));
        harness.act{value: 1 ether - 1}(0, Action.SendObserver);
    }

    function test_Fee_ExactPasses() public {
        source.setFee(1 ether);
        vm.deal(player, 5 ether);
        _write(_game(), _unsurveyed());

        harness.act{value: 1 ether}(0, Action.SendObserver);
        assertTrue(harness.getPending(player).active, "commit succeeded at exact fee");
        assertEq(address(source).balance, 1 ether, "fee forwarded to the source");
    }

    function test_Fee_OverpayRefundsChange() public {
        source.setFee(1 ether);
        vm.deal(player, 5 ether);
        _write(_game(), _unsurveyed());

        uint256 balBefore = player.balance;
        harness.act{value: 1.5 ether}(0, Action.SendObserver);

        assertTrue(harness.getPending(player).active, "commit succeeded");
        assertEq(address(source).balance, 1 ether, "only the fee is forwarded");
        assertEq(player.balance, balBefore - 1 ether, "change (0.5) refunded");
    }

    // ── Cancellation when the world changes under the request (Ticket 4.4 §4.2) ──

    function test_Cancel_WhenPortalCollapsesBeforeReveal() public {
        Portal memory p = _unsurveyed();
        p.hoursToCollapse = 2; // collapses soon after commit
        _write(_game(), p);

        harness.act(0, Action.SendObserver); // commit at hour 0
        uint64 reqId = harness.getPending(player).requestId;

        // Wait past the collapse, then the word finally arrives.
        vm.warp(BASE + 3 * SPH);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.SurveyCancelled(player, 0, reqId, 10, 3); // powerRefunded = costSendObserver
        source.reveal(reqId);

        // Deferral resolved, nothing left pending.
        assertFalse(harness.getPending(player).active, "pending cleared on cancel");

        Portal memory after_ = _portal(0);
        assertEq(uint8(after_.status), uint8(PortalStatus.Empty), "collapsed portal freed");
        assertFalse(after_.surveyed, "never surveyed");

        Game memory g = harness.getGame(player);
        assertFalse(g.finished, "game still alive");
        // Observer that walked in died with the portal: not returned to the pool.
        assertEq(g.observersFree, 2, "observer lost in the collapse, not refunded");
        // HP took the collapse (base 20 + 1 death [the observer] * 8 = 28).
        assertEq(g.hp, 72, "collapse cost HP"); // 100 - 28
    }

    // ── startGame while a survey is pending (owner's call: deferral dies) ─────────

    function test_StartGame_DropsPendingAndOrphansLateDelivery() public {
        _write(_game(), _unsurveyed());
        harness.act(0, Action.SendObserver);
        uint64 reqId = harness.getPending(player).requestId;

        // Start a fresh game while the survey is still in flight.
        harness.startGame();
        assertFalse(harness.getPending(player).active, "pending wiped by startGame");

        // A late delivery for the dead request is rejected, not applied.
        vm.prank(address(source));
        vm.expectRevert(PortalLab.UnknownRequest.selector);
        harness.receiveWord(player, reqId, uint256(keccak256("late")));
    }

    // ── Reveal-phase gas budget (Ticket 4.4 §4.4) ────────────────────────────────

    function test_Gas_RevealWorstCase_UnderBudget() public {
        // Worst case for the reveal: a full 12-portal world where the catch-up at
        // reveal processes a wave of collapses AND fills freed slots with fresh
        // spawns, then applies the survey. Eleven empty portals collapse (3 HP
        // each = 33, game survives from 100), the survey target survives.
        Game memory g = _game();
        g.hp = 100;
        g.openPortals = 12;
        harness.setGame(player, g);

        // Slot 0: the survey target, long-lived so it outlives the window.
        harness.setPortal(player, 0, _unsurveyed());

        // Slots 1..11: empty portals collapsing at staggered hours 1..11.
        for (uint8 i = 1; i < 12; i++) {
            Portal memory e = _unsurveyed();
            e.creaturesKnown = true; // empty, no creatures → empty collapse (cheap HP)
            e.creaturesLo = 0;
            e.creaturesHi = 0;
            e.hoursToCollapse = i; // collapses within the warp window
            harness.setPortal(player, i, e);
        }

        harness.act(0, Action.SendObserver); // commit
        uint64 reqId = harness.getPending(player).requestId;

        // Long catch-up: all eleven collapse, pressure accrues, slots refill.
        vm.warp(BASE + 12 * SPH);

        uint256 before = gasleft();
        source.reveal(reqId);
        uint256 used = before - gasleft();

        console2.log("reveal worst-case gas used (incl. source dispatch):", used);
        // The Pyth callback gas limit is 1 000 000; a blocker is anything closer
        // than a third of it (>= 666 667). We must sit comfortably below.
        assertLt(used, 666_667, "reveal must stay well under the 1M callback limit");

        // The survey still applied (target survived the wave).
        assertTrue(_portal(0).surveyed, "survey applied despite the heavy catch-up");
        assertFalse(harness.getGame(player).finished, "game survived the wave");
    }
}
