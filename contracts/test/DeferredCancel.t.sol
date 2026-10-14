// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Game,
    Portal,
    PortalType,
    PortalStatus,
    Action,
    Refusal,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title DeferredCancelTest — Ticket 4.5a: cancelled deferred actions must not
/// disappear silently.
/// @notice Covers three scenarios:
///   4.1  Portal collapses between commit and reveal → DeferredActionCancelled.
///   4.2  Game ends in the catch-up window → DeferredActionCancelled + GameOver.
///   4.3  `preview` reports cappedShort correctly in both directions.
contract DeferredCancelTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1_000_000;
    uint32 internal SPH;
    uint32 internal EPH;

    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);

        SPH = DefaultConfig.config().secPerHour;
        EPH = DefaultConfig.config().epochHours;

        vm.warp(BASE);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Minimal game at BASE with nothing pinned (coveredEpochs = 0), so any
    /// warp >= 1 game-hour puts the world behind its epoch edge and triggers a
    /// crossing deferral.
    function _bareGame(uint16 hp) internal {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = hp;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
        harness.setGame(player, g);
        harness.setCoverage(player, uint256(keccak256("seed")), 0);
    }

    // ── 4.1: portal collapses between commit and reveal ───────────────────────

    /// Commit a ToggleQuestioned on slot 1 when the world is capped at hour 0
    /// (nothing pinned). The portal collapses at hour 1. On reveal the catch-up
    /// processes the collapse; spawn pressure is enough for one new portal, which
    /// fills slot 0 (the lowest-indexed free slot). Slot 1 remains empty.
    /// `_performDeferredAction` finds slot 1 empty and emits
    /// `DeferredActionCancelled(reason = PortalEmpty)`. The world is still advanced
    /// — the collapse and the spawn both stand.
    function test_4_1_DeferredActionCancelled_PortalCollapses() public {
        _bareGame(100);

        // Portal at SLOT 1 with hoursToCollapse = 1 and no creatures (penalty = 3 HP).
        // Slot 0 is intentionally left empty: after the collapse the spawn fills
        // slot 0, leaving slot 1 empty — so the deferred action finds it gone.
        Portal memory p;
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1;
        p.creaturesKnown = true;
        p.creatures = 0;
        p.creaturesLo = 0;
        p.creaturesHi = 0;
        harness.setPortal(player, 1, p);

        // Warp to 1 game-hour: hNow = 1, hWalkEnd = 0 (coveredEpochs = 0) → cappedShort.
        vm.warp(BASE + SPH);
        harness.act(1, Action.ToggleQuestioned);
        assertTrue(harness.getPending(player).active, "action deferred at epoch edge");
        uint64 reqId = harness.getPending(player).requestId;

        // Warp to hour 13 for the reveal: after the first birth (hour 10, slot 0)
        // and before the second (hour 20), which would otherwise refill slot 1
        // (it was EPH + 1 = 13 with epochHours 12; at 36 the reveal hour 37 sees
        // two births and the slot is occupied again).
        uint32 revealHour = 13;
        vm.warp(BASE + uint256(revealHour) * SPH);

        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(
            player, 1, Action.ToggleQuestioned, Refusal.PortalEmpty, reqId, revealHour
        );
        source.reveal(reqId);

        // Deferral resolved; world advanced to the reveal hour.
        assertFalse(harness.getPending(player).active, "deferral resolved");
        assertEq(harness.getGame(player).hoursElapsed, revealHour, "world advanced to reveal hour");
        // The collapse happened: slot 1 is now empty (plus one new spawn at slot 0).
        assertEq(uint8(harness.getPortals(player)[1].status), uint8(PortalStatus.Empty), "slot 1 empty after collapse");
    }

    // ── 4.2: game ends in the catch-up window during a crossing reveal ────────

    /// The game starts with low HP. The portal collapses at hour 1, dealing
    /// 40 HP (base 20 + 10 × 2 creatures) which exceeds the 30 HP available.
    /// On reveal the catch-up detects the death; `_revealCrossing` emits
    /// `GameOver` and then `DeferredActionCancelled(reason = GameNotActive)`.
    /// The syncOnly case is NOT emitted (a paid sync carries no action).
    function test_4_2_DeferredActionCancelled_GameDiesInCatchup() public {
        _bareGame(30); // 30 HP < 40 HP collapse penalty → dies at hour 1

        Portal memory p;
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1;
        p.creaturesKnown = true;
        p.creatures = 2; // hpLost = 20 + 10*2 = 40
        p.creaturesLo = 2;
        p.creaturesHi = 2;
        harness.setPortal(player, 0, p);

        vm.warp(BASE + SPH);
        harness.act(0, Action.ToggleQuestioned);
        uint64 reqId = harness.getPending(player).requestId;

        vm.warp(BASE + uint256(EPH + 1) * SPH);

        // 1. PortalCollapsed — deaths=2, hpLost=30 (the HP actually left, nominal is 40), at hour 1.
        vm.expectEmit(true, true, false, true);
        emit PortalLab.PortalCollapsed(player, 0, 2, 30, 1);
        // 2. GameOver — game froze at the collapse hour.
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameOver(player, 1);
        // 3. DeferredActionCancelled — action never executed.
        vm.expectEmit(true, true, false, true);
        emit PortalLab.DeferredActionCancelled(
            player, 0, Action.ToggleQuestioned, Refusal.GameNotActive, reqId, 1
        );
        source.reveal(reqId);

        assertTrue(harness.getGame(player).finished, "game ended");
        assertEq(harness.getGame(player).diedAtHour, 1, "death recorded at hour 1");
        assertFalse(harness.getPending(player).active, "deferral resolved");
    }

    /// A paid sync deferral (syncOnly = true) carries NO action. When the game
    /// ends in the catch-up window, only GameOver is emitted — no cancellation
    /// event, because there was nothing to cancel. This silence is intentional
    /// and documented in _revealCrossing.
    function test_4_2_SyncOnly_NoActionEvent_OnDeath() public {
        _bareGame(30);

        Portal memory p;
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1;
        p.creaturesKnown = true;
        p.creatures = 2;
        p.creaturesLo = 2;
        p.creaturesHi = 2;
        harness.setPortal(player, 0, p);

        // A paid sync creates a syncOnly deferral.
        vm.warp(BASE + SPH);
        harness.sync{value: 1}(player);
        assertTrue(harness.getPending(player).active, "sync deferred");
        assertTrue(harness.getPending(player).syncOnly, "syncOnly flag set");
        uint64 reqId = harness.getPending(player).requestId;

        vm.warp(BASE + uint256(EPH + 1) * SPH);

        // Only GameOver — no DeferredActionCancelled for a syncOnly deferral.
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameOver(player, 1);
        source.reveal(reqId);

        assertTrue(harness.getGame(player).finished, "game ended");
    }

    // ── 4.3: preview returns cappedShort correctly ────────────────────────────

    /// When no epoch is pinned and real time has advanced past epoch 0, the free
    /// catch-up cannot reach `block.timestamp` — `cappedShort` must be true.
    function test_4_3_Preview_CappedShort_True() public {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g);
        harness.setCoverage(player, 0, 0); // nothing pinned

        vm.warp(BASE + uint256(5 * EPH) * SPH);
        (,, bool capped) = harness.preview(player);
        assertTrue(capped, "cappedShort is true when no epoch is pinned");
    }

    /// With generous coverage (`setGame` pins coveredEpochs = max), the world
    /// reaches `block.timestamp` and `cappedShort` is false.
    function test_4_3_Preview_CappedShort_False() public {
        Game memory g;
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 60_000; // durable: a 100-hp empty lab dies at hour 49, before 2 * EPH = 72
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        harness.setGame(player, g); // setGame pins coveredEpochs = type(uint32).max

        vm.warp(BASE + uint256(2 * EPH) * SPH);
        (Game memory gp,, bool capped) = harness.preview(player);
        assertFalse(capped, "cappedShort is false with ample coverage");
        assertEq(gp.hoursElapsed, 2 * EPH, "world reached now");
    }
}
