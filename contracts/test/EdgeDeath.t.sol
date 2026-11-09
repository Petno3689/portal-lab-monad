// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PortalLab} from "../src/PortalLab.sol";
import {
    Config,
    Game,
    BestRun,
    Portal,
    Pending,
    PortalType,
    PortalStatus,
    Action
} from "../src/PortalLabTypes.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";
import {DeterministicSource} from "./utils/DeterministicSource.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";

/// @title EdgeDeathTest — Ticket F1a: not paying for the next word never scores
/// more than paying on. A run abandoned beyond the pinned edge is recorded at the
/// edge; a cancelled epoch crossing ends the run there; a 0-hour run is not listed.
///
/// `DefaultConfig`: secPerHour 15, epochHours 36, hpStart 80, hpOverflowPerHour 5,
/// basePressurePerHour 1000, pressureRampPerHour 2, spawnCostUnits 10_000,
/// MAX_OPEN_PORTALS 12 (a full lab needs 120_000 units). Pressure over [a, b):
///   P(a, b) = 1000*(b-a) + 2*((a+b-1)*(b-a))/2,   so P(107, 107+k) = 1213k + k^2.
/// States are built fresh by helpers (never assigned by copy — CLAUDE.md rule).
contract EdgeDeathTest is Test {
    PortalLabHarness internal harness;
    DeterministicSource internal source;
    address internal player;

    uint40 internal constant BASE = 1_000_000;
    uint32 internal SPH;
    uint32 internal EPH;
    uint256 internal TIMEOUT; // seconds, the player's own timeout
    uint256 internal OUTSIDER_TIMEOUT; // seconds, what a stranger must wait

    address internal constant STRANGER = address(0xBEEF);

    receive() external payable {}

    function setUp() public {
        harness = new PortalLabHarness();
        source = harness.source();
        player = address(this);
        Config memory c = DefaultConfig.config();
        SPH = c.secPerHour;
        EPH = c.epochHours;
        TIMEOUT = uint256(c.requestTimeoutHours) * SPH;
        OUTSIDER_TIMEOUT = uint256(c.outsiderTimeoutHours) * SPH;
        vm.warp(BASE);
        vm.deal(address(this), 1 ether);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _game(uint16 power) internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 100;
        g.power = power;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 1;
    }

    /// @dev An empty lab already stamped at game hour `h`, with `hp` and `debt`.
    function _emptyLabAt(uint32 h, uint16 hp, uint32 debt) internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE + uint40(h) * 15;
        g.hoursElapsed = h;
        g.hp = hp;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.spawnDebt = debt;
    }

    /// @dev A finished, unsettled run of `hrs` hours.
    function _deadGame(uint32 hrs) internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.finished = true;
        g.diedAtHour = hrs;
        g.hoursElapsed = hrs;
    }

    function _unsurveyed() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.portalType = PortalType.LongLived;
        p.snapshotAt = BASE;
        p.hoursToCollapse = 1000;
        p.energyHi = 5;
        p.stabilityLo = 95;
        p.stabilityHi = 100;
        p.creaturesLo = 2;
        p.creaturesHi = 3;
    }

    function _atHour(uint256 startedAt, uint256 h) internal view returns (uint256) {
        return startedAt + h * uint256(SPH);
    }

    /// @dev Stuck epoch-crossing action: epoch 0 pinned, world one hour past its edge.
    function _commitCrossing() internal {
        harness.setGame(player, _game(50));
        harness.setPortal(player, 0, _unsurveyed());
        harness.setCoverage(player, uint256(keccak256("seed")), 1);
        vm.warp(BASE + uint256(EPH + 1) * SPH);
        harness.act(0, Action.SendObserver);
        assertTrue(harness.getPending(player).deferredWorld, "crossing deferral");
        assertFalse(harness.getPending(player).syncOnly, "an action, not a sync");
    }

    /// @dev Stuck paid sync: epoch 0 pinned, world one hour past its edge.
    function _commitPaidSync() internal {
        harness.setGame(player, _game(50));
        harness.setCoverage(player, uint256(keccak256("seed")), 1);
        vm.warp(BASE + uint256(EPH + 1) * SPH);
        harness.sync{value: 1}(player);
        Pending memory pend = harness.getPending(player);
        assertTrue(pend.active && pend.syncOnly && pend.deferredWorld, "sync deferral");
    }

    function _countGameOver(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == PortalLab.GameOver.selector) n++;
        }
    }

    /// @dev Cancel the stuck crossing as `caller`, then check the run ended at the
    /// pinned edge with GameOver emitted once, and that settle records the edge.
    function _cancelEndsRunAtEdge(address caller) internal {
        uint256 edge = uint256(EPH) - 1;
        vm.recordLogs();
        vm.prank(caller);
        harness.cancelDeferred(player);
        assertEq(_countGameOver(vm.getRecordedLogs()), 1, "GameOver emitted once");

        Game memory g = harness.getGame(player);
        assertTrue(g.finished, "finished");
        assertEq(g.hp, 0, "hp 0");
        assertEq(g.diedAtHour, edge, "died at the pinned edge");
        assertEq(g.hoursElapsed, edge, "clock stopped at the edge");
        assertEq(g.lastTickAt, _atHour(BASE, edge), "stamp unchanged: the edge");
        assertFalse(harness.getPending(player).active, "lock released");

        vm.recordLogs();
        harness.settle(player);
        assertEq(_countGameOver(vm.getRecordedLogs()), 0, "no second GameOver on settle");
        assertEq(harness.bestRun(player).hoursSurvived, edge, "settle records the edge");
    }

    // ── No word: the run is recorded at hour 0 ───────────────────────────────

    /// A game started without a word never leaves hour 0: the abandoned-lab trigger
    /// (84 + 16 = 100) ends it, and it is recorded at 0 and not listed.
    function test_NoWord_RecordedAtZero_NotListed() public {
        address p = address(0xA0);
        vm.prank(p);
        harness.startGame();

        vm.warp(_atHour(BASE, 99));
        vm.expectRevert(PortalLab.GameNotFinished.selector);
        harness.settle(p);

        vm.warp(_atHour(BASE, 100));
        harness.settle(p);

        BestRun memory b = harness.bestRun(p);
        assertEq(b.hoursSurvived, 0, "recorded at hour 0");
        assertEq(b.runsSettled, 1, "the run is counted");
        assertEq(harness.getGame(p).spawnCount, 0, "no portal was ever born");
        assertEq(harness.leaderboardSize(), 0, "a 0-hour run is not listed");
    }

    // ── Property: abandoning never scores more than paying on ────────────────

    /// For real worlds alive one hour past edge 35: abandoning records exactly 35;
    /// paying on (idle, a paid sync every 12 h) dies strictly later.
    function test_AbandonNeverBeatsPaying() public {
        uint256 edge = uint256(EPH) - 1;
        uint256 found = 0;
        for (uint256 i = 0; i < 64 && found < 8; i++) {
            address p = address(uint160(0x10000 + i));
            vm.deal(p, 1 ether);
            vm.prank(p);
            harness.startGame{value: 1}();
            harness.reveal(p);
            uint256 start = harness.getGame(p).startedAt;

            vm.warp(_atHour(start, edge + 1));
            harness.sync(p); // free: stamps the world at the edge
            if (harness.getGame(p).finished) continue;
            assertEq(harness.getGame(p).hoursElapsed, edge, "stamped at the edge");
            found++;

            uint256 snap = vm.snapshotState();

            // (A) Abandon: nobody pays; settle much later.
            vm.warp(_atHour(start, 3000));
            harness.settle(p);
            assertEq(harness.getGame(p).diedAtHour, edge, "abandoned: recorded at the edge");

            vm.revertToState(snap);

            // (B) Stay idle but keep paying for the next word.
            for (uint256 k = 0; k < 1000 && !harness.getGame(p).finished; k++) {
                vm.warp(_atHour(start, edge + 1 + 12 * k));
                harness.sync{value: 1}(p);
                if (harness.getPending(p).active) harness.reveal(p);
            }
            assertTrue(harness.getGame(p).finished, "paying on, the idle lab still dies");
            assertGt(harness.getGame(p).diedAtHour, edge, "paying on lives past the edge");
        }
        assertGe(found, 4, "at least four worlds alive past the edge");
    }

    // ── Harness states at a non-zero pinned edge ─────────────────────────────

    /// Empty lab, HP 100, three epochs pinned (edge 107): fill at 107 + 92 = 199,
    /// trigger 199 + 20 = 219 (once recorded); now recorded at 107.
    function test_EmptyLabAtEdge107_RecordedAt107() public {
        harness.setGame(player, _emptyLabAt(107, 100, 0));
        harness.setCoverage(player, uint256(keccak256("seed")), 3);

        vm.warp(_atHour(BASE, 218));
        vm.expectRevert(PortalLab.GameNotFinished.selector);
        harness.settle(player);

        vm.warp(_atHour(BASE, 5000));
        harness.settle(player);
        assertEq(harness.bestRun(player).hoursSurvived, 107, "recorded at the edge, not 219");
    }

    /// Trigger exactness at edge E = 107: debt 1336 + P(107, 198) = 1336 + 118_664
    /// = 120_000 exactly (and 1336 + P(107, 197) = 118_606 < 120_000), so
    /// hFill = 198; hp 60 -> + ceil(60/5) = 12 -> trigger T = 210.
    function test_TriggerExact_NonZeroEdge() public {
        harness.setGame(player, _emptyLabAt(107, 60, 1336));
        harness.setCoverage(player, uint256(keccak256("seed")), 3);

        vm.warp(_atHour(BASE, 209));
        vm.expectRevert(PortalLab.GameNotFinished.selector);
        harness.settle(player);

        vm.warp(_atHour(BASE, 210));
        harness.settle(player);
        Game memory g = harness.getGame(player);
        assertTrue(g.finished, "over at the trigger");
        assertEq(g.diedAtHour, 107, "recorded at the edge E");
        assertEq(g.lastTickAt, _atHour(BASE, 107), "clock stopped at the edge");
    }

    // ── Leaderboard listing ──────────────────────────────────────────────────

    function test_Leaderboard_ListedOnceWhenBestRisesAboveZero() public {
        address p = address(0xA1);
        vm.prank(p);
        harness.startGame();
        vm.warp(_atHour(BASE, 100));
        harness.settle(p);
        assertEq(harness.bestRun(p).hoursSurvived, 0);
        assertEq(harness.leaderboardSize(), 0, "first run of 0 h: not listed");

        harness.setGame(p, _deadGame(10));
        harness.settle(p);
        assertEq(harness.leaderboardSize(), 1, "a 10 h run lists the player");
        assertEq(harness.bestRun(p).runsSettled, 2);

        harness.setGame(p, _deadGame(20));
        harness.settle(p);
        assertEq(harness.leaderboardSize(), 1, "listed only once");
        assertEq(harness.bestRun(p).hoursSurvived, 20);
        assertEq(harness.bestRun(p).runsSettled, 3);
    }

    // ── Crossing cancel ends the run at the edge ─────────────────────────────

    function test_CancelCrossingAction_ByPlayer_EndsAtEdge() public {
        _commitCrossing();
        vm.warp(block.timestamp + TIMEOUT + 1);
        _cancelEndsRunAtEdge(player);
    }

    function test_CancelPaidSync_ByPlayer_EndsAtEdge() public {
        _commitPaidSync();
        vm.warp(block.timestamp + TIMEOUT + 1);
        _cancelEndsRunAtEdge(player);
    }

    function test_CancelCrossing_ByStranger_EndsAtEdge() public {
        _commitCrossing();
        vm.warp(block.timestamp + OUTSIDER_TIMEOUT + 1);
        _cancelEndsRunAtEdge(STRANGER);
    }

    function test_CancelSurvey_GameStaysAlive() public {
        harness.setGame(player, _game(50));
        harness.setPortal(player, 0, _unsurveyed());
        harness.act(0, Action.SendObserver);
        assertFalse(harness.getPending(player).deferredWorld, "in-epoch survey");
        vm.warp(BASE + TIMEOUT + 1);
        harness.cancelDeferred(player);
        assertFalse(harness.getGame(player).finished, "a survey cancel does not end the run");
        assertFalse(harness.getPending(player).active, "lock released");
    }

    // ── A late word on a run already recorded at the edge ────────────────────

    function test_LateWord_AfterEdgeSettle_Harmless() public {
        _commitPaidSync();
        uint64 reqId = harness.getPending(player).requestId;
        assertTrue(source.isPending(reqId), "request pending");

        vm.warp(_atHour(BASE, 3000)); // far past the tail trigger
        vm.prank(STRANGER);
        harness.settle(player);
        Game memory settled = harness.getGame(player);
        assertTrue(settled.finished);
        assertEq(settled.diedAtHour, uint256(EPH) - 1, "a stranger's settle records the edge");
        assertEq(harness.bestRun(player).hoursSurvived, uint256(EPH) - 1);

        bytes32 gameHash = keccak256(abi.encode(harness.getGame(player)));
        bytes32 portalsHash = keccak256(abi.encode(harness.getPortals(player)));
        source.reveal(reqId); // must not revert
        assertEq(keccak256(abi.encode(harness.getGame(player))), gameHash, "game unchanged");
        assertEq(keccak256(abi.encode(harness.getPortals(player))), portalsHash, "portals unchanged");
        assertTrue(harness.getGame(player).finished);
        assertEq(harness.getGame(player).diedAtHour, uint256(EPH) - 1, "same diedAtHour");
        assertFalse(harness.getPending(player).active, "pending cleared");
    }
}
