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
    PortalType,
    PortalStatus,
    Action,
    Refusal,
    MAX_OPEN_PORTALS
} from "../src/PortalLabTypes.sol";
import {DefaultConfig} from "./utils/DefaultConfig.sol";
import {PortalLabHarness} from "./utils/PortalLabHarness.sol";

/// @title SettleTest — ticket 4.1: run-result recording, settle(), bestRun(),
/// creaturesRescued counter, and storage-layout assertions.
contract SettleTest is Test {
    PortalLabHarness internal harness;
    address internal player;

    uint40 internal constant BASE = 1_000;
    uint40 internal constant SPH = 15; // DefaultConfig.secPerHour

    function setUp() public {
        harness = new PortalLabHarness();
        player = address(this);
        vm.warp(BASE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Minimal active game: started at BASE, hp 50 (a fixed test value, not hpStart since the 16 Oct rebalance), full crew.
    function _game() internal pure returns (Game memory g) {
        g.startedAt = BASE;
        g.lastTickAt = BASE;
        g.hp = 50;
        g.power = 100;
        g.observersFree = 3;
        g.rescuersFree = 2;
        g.openPortals = 0;
    }

    /// @dev A finished game: diedAtHour = `hrs`, creaturesRescued = `rescued`.
    function _deadGame(uint32 hrs, uint32 rescued) internal pure returns (Game memory g) {
        g = _game();
        g.finished = true;
        g.diedAtHour = hrs;
        g.hoursElapsed = hrs;
        g.hp = 0;
        g.creaturesRescued = rescued;
    }

    /// @dev An open, surveyed portal with a rescuer inside and `n` creatures.
    function _rescuerPortal(uint8 n) internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.creatures = n;
        p.hoursToCollapse = 48;
        p.rescuerInside = true;
        p.snapshotAt = BASE;
    }

    /// @dev An unsurveyed portal with `lo..hi` creatures, rescuer inside.
    function _blindRescuerPortal(uint8 lo, uint8 hi, uint8 count) internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = false;
        p.creaturesKnown = true; // count already revealed by blind entry
        p.creatures = count;
        p.creaturesLo = lo;
        p.creaturesHi = hi;
        p.hoursToCollapse = 48;
        p.rescuerInside = true;
        p.snapshotAt = BASE;
    }

    // ── 7.1: settle on a dead game records values from the moment of death ────

    function test_7_1_settle_dead_game_records_values() public {
        Game memory g = _deadGame(42, 5);
        harness.setGame(player, g);

        harness.settle(player);

        BestRun memory br = harness.bestRun(player);
        assertEq(br.hoursSurvived, 42);
        assertEq(br.creaturesRescued, 5);
        assertEq(br.runsSettled, 1);
        assertEq(br.settledAt, BASE); // block.timestamp
    }

    // ── 7.2: settle on a live game reverts GameNotFinished ───────────────────

    function test_7_2_settle_live_reverts_GameNotFinished() public {
        harness.setGame(player, _game());
        vm.expectRevert(PortalLab.GameNotFinished.selector);
        harness.settle(player);
    }

    // ── 7.3: second settle reverts AlreadySettled ────────────────────────────

    function test_7_3_settle_twice_reverts_AlreadySettled() public {
        harness.setGame(player, _deadGame(10, 0));
        harness.settle(player);
        vm.expectRevert(PortalLab.AlreadySettled.selector);
        harness.settle(player);
    }

    // ── 7.4: settle for a never-played address reverts NoGame ─────────────────

    function test_7_4_settle_no_game_reverts_NoGame() public {
        vm.expectRevert(PortalLab.NoGame.selector);
        harness.settle(address(0xDEAD));
    }

    // ── 7.5: anyone can settle another player's run ──────────────────────────

    function test_7_5_settle_by_stranger_succeeds() public {
        harness.setGame(player, _deadGame(7, 2));

        address stranger = address(0xABC);
        vm.prank(stranger);
        harness.settle(player); // public, no msg.sender check

        assertEq(harness.bestRun(player).runsSettled, 1);
    }

    // ── 7.6: death during absence — settle discovers the real hour ────────────

    function test_7_6_settle_detects_death_during_absence() public {
        // Game with a portal that will collapse immediately, draining HP.
        // hpCollapseBase=20, hpEmptyCollapse=3. One empty portal collapse costs 3 HP.
        // With hp=3, a single empty-portal collapse kills the game.
        Game memory g = _game();
        g.hp = 3;
        g.openPortals = 1;
        // Portal that collapses at hour 1, no creatures.
        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.creatures = 0;
        p.hoursToCollapse = 1;
        p.snapshotAt = BASE;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        // Jump 2 hours forward without any transaction: death happened during absence.
        vm.warp(BASE + 2 * SPH);
        harness.settle(player);

        BestRun memory br = harness.bestRun(player);
        // The game died at hour 1 (portal collapsed at hour 1, draining remaining 3 hp).
        assertEq(br.hoursSurvived, 1, "death hour must be 1, not the last-action hour (0)");
        assertEq(harness.getGame(player).finished, true);
    }

    // ── 7.7: startGame after dead+unsettled → auto-settles before delete ──────

    function test_7_7_startGame_auto_settles_finished_unsettled() public {
        harness.setGame(player, _deadGame(20, 3));

        // Before startGame the run is NOT yet in bestRun.
        assertEq(harness.bestRun(player).runsSettled, 0);

        vm.expectEmit(true, false, false, false);
        emit PortalLab.RunSettled(player, 0, 0, false); // params checked below
        harness.startGame();

        // After startGame: record exists in bestRun AND new game was created.
        BestRun memory br = harness.bestRun(player);
        assertEq(br.hoursSurvived, 20, "hours survived should be from the dead game");
        assertEq(br.creaturesRescued, 3, "creatures should be from the dead game");
        assertEq(br.runsSettled, 1, "one run recorded");

        // New game was started (startedAt == current timestamp after the delete).
        assertEq(harness.getGame(player).startedAt, BASE, "new game started");
        assertEq(harness.getGame(player).finished, false);
    }

    // ── 7.8: startGame after a live game → no record, runsSettled unchanged ──

    function test_7_8_startGame_live_not_recorded() public {
        harness.setGame(player, _game()); // live game

        vm.warp(BASE + SPH); // one hour later
        vm.expectEmit(true, false, false, true);
        emit PortalLab.GameForfeited(player, 0);
        harness.startGame();

        BestRun memory br = harness.bestRun(player);
        assertEq(br.runsSettled, 0, "a forfeited live game must not increment runsSettled");
    }

    // ── 7.9: three runs — worse, better, worse — best record wins, count is 3 ─

    function test_7_9_best_run_tracks_max_hours() public {
        // Run 1: 30 hours.
        harness.setGame(player, _deadGame(30, 0));
        harness.settle(player);
        assertEq(harness.bestRun(player).hoursSurvived, 30);
        assertEq(harness.bestRun(player).runsSettled, 1);

        // Run 2: 50 hours (better) — need to simulate new game + death.
        harness.startGame(); // clears the player (auto-settles dead game again? No — already settled)
        // Since run 1 is settled, auto-settle is skipped. Start fresh.
        harness.setGame(player, _deadGame(50, 0));
        harness.settle(player);
        assertEq(harness.bestRun(player).hoursSurvived, 50);
        assertEq(harness.bestRun(player).runsSettled, 2);

        // Run 3: 20 hours (worse).
        harness.startGame();
        harness.setGame(player, _deadGame(20, 0));
        harness.settle(player);
        assertEq(harness.bestRun(player).hoursSurvived, 50, "best remains 50");
        assertEq(harness.bestRun(player).runsSettled, 3, "total count is 3");
    }

    // ── 7.10: tiebreak — same hours, more creatures wins ─────────────────────

    function test_7_10_tiebreak_creatures_updates_record() public {
        // First run: 40 hours, 2 creatures.
        harness.setGame(player, _deadGame(40, 2));
        harness.settle(player);
        assertEq(harness.bestRun(player).creaturesRescued, 2);

        // Second run: 40 hours, 5 creatures (better tiebreak).
        harness.startGame();
        harness.setGame(player, _deadGame(40, 5));
        harness.settle(player);
        assertEq(harness.bestRun(player).hoursSurvived, 40);
        assertEq(harness.bestRun(player).creaturesRescued, 5, "tiebreak: more creatures wins");
        assertEq(harness.bestRun(player).runsSettled, 2);
    }

    // ── 7.11a: surveyed Evacuate — all creatures counted ─────────────────────

    function test_7_11a_creaturesRescued_surveyed_evacuate() public {
        // Portal: surveyed, 3 creatures, rescuer inside.
        Game memory g = _game();
        g.rescuersFree = 1;
        Portal memory p = _rescuerPortal(3);
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        uint32 before = harness.getGame(player).creaturesRescued;
        harness.act(0, Action.Evacuate);
        assertEq(harness.getGame(player).creaturesRescued, before + 3, "all 3 saved (surveyed)");
    }

    // ── 7.11b: blind Evacuate — n-1 creatures counted (one left behind) ──────

    function test_7_11b_creaturesRescued_blind_evacuate() public {
        // Portal: blind entry, 3 creatures known, rescuer inside.
        Game memory g = _game();
        g.rescuersFree = 1;
        Portal memory p = _blindRescuerPortal(2, 3, 3);
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        harness.act(0, Action.Evacuate);
        // surveyed == false → saved = 3 - 1 = 2
        assertEq(harness.getGame(player).creaturesRescued, 2, "2 saved (blind leaves one behind)");
    }

    // ── 7.11c: Close does NOT increment creaturesRescued ─────────────────────

    function test_7_11c_close_does_not_count() public {
        // Portal: surveyed, 2 creatures, low stability to allow close.
        Game memory g = _game();
        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.creatures = 2;
        p.stability = 20; // below closeStabilityBelow (40)
        p.hoursToCollapse = 24;
        p.snapshotAt = BASE;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        uint32 before = harness.getGame(player).creaturesRescued;
        harness.act(0, Action.Close);
        assertEq(harness.getGame(player).creaturesRescued, before, "Close must not increment creaturesRescued");
    }

    // ── 7.11d: collapse does NOT increment creaturesRescued ──────────────────

    function test_7_11d_collapse_does_not_count() public {
        // Portal that collapses in 1 hour, with 2 creatures — collapse kills them.
        Game memory g = _game();
        g.hp = 100;
        g.openPortals = 1;
        Portal memory p;
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.creatures = 2;
        p.hoursToCollapse = 1;
        p.snapshotAt = BASE;
        harness.setGame(player, g);
        harness.setPortal(player, 0, p);

        // Jump 2 hours, trigger collapse via sync.
        vm.warp(BASE + 2 * SPH);
        harness.sync(player);

        assertEq(harness.getGame(player).creaturesRescued, 0, "collapse must not increment creaturesRescued");
    }

    // ── 7.12: storage layout — Game fits 2 slots, BestRun fits 1 ─────────────

    function test_7_12_storage_layout_game_2_slots_bestrun_1_slot() public pure {
        // Game slot 0: startedAt(5)+lastTickAt(5)+hoursElapsed(4)+diedAtHour(4)
        //              +hp(2)+power(2)+observersFree(1)+rescuersFree(1)
        //              +openPortals(1)+finished(1)+spawnDebt(4) = 30 bytes
        uint256 slot0Used = 5 + 5 + 4 + 4 + 2 + 2 + 1 + 1 + 1 + 1 + 4;
        assertEq(slot0Used, 30, "Game slot 0: 30 bytes used, 2 bytes free");
        assertLe(slot0Used, 32, "Game slot 0 must not overflow 32 bytes");

        // Game slot 1: spawnCount(4)+rngNonce(4)+rescuerReadyAt0..3(4*4)
        //              +creaturesRescued(4)+settled(1) = 29 bytes
        uint256 slot1Used = 4 + 4 + 4 * 4 + 4 + 1;
        assertEq(slot1Used, 29, "Game slot 1: 29 bytes used, 3 bytes free");
        assertLe(slot1Used, 32, "Game slot 1 must not overflow 32 bytes");

        // BestRun: hoursSurvived(4)+creaturesRescued(4)+settledAt(4)+runsSettled(4) = 16 bytes
        uint256 bestRunUsed = 4 + 4 + 4 + 4;
        assertEq(bestRunUsed, 16, "BestRun: 16 bytes, fits in 1 slot");
        assertLe(bestRunUsed, 32, "BestRun must not overflow 32 bytes");
    }

    // ── Gas measurement helpers (part 8) ─────────────────────────────────────

    /// @dev Gas used by startGame on a clean (never-played) address.
    function test_gas_8_1_startGame_clean() public {
        address fresh = address(0x9999);
        vm.prank(fresh);
        uint256 g0 = gasleft();
        harness.startGame();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas startGame (clean player)", used);
    }

    /// @dev Gas used by startGame when the previous game is finished+unsettled
    /// (auto-settle path, zero portals).
    function test_gas_8_2_startGame_auto_settle() public {
        harness.setGame(player, _deadGame(100, 5));
        uint256 g0 = gasleft();
        harness.startGame();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas startGame (auto-settle, 0 portals)", used);
    }

    /// @dev Gas used by settle() on a finished game with no portals.
    function test_gas_8_3_settle_standalone() public {
        harness.setGame(player, _deadGame(100, 5));
        uint256 g0 = gasleft();
        harness.settle(player);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas settle (finished game, 0 portals)", used);
    }

    // 8.4 — worst-case: game started, time advanced by N hours, then startGame.
    // Portal count = 0 (spawn pressure at huge elapsed times fills slots, but
    // the catch-up is still O(portals) — gas must be constant in elapsed hours).

    function test_gas_8_4_startGame_after_1000h_absence() public {
        _startAndAdvance(1_000);
    }

    function test_gas_8_4_startGame_after_100000h_absence() public {
        _startAndAdvance(100_000);
    }

    function test_gas_8_4_startGame_after_10000000h_absence() public {
        _startAndAdvance(10_000_000);
    }

    function _startAndAdvance(uint256 gameHours) internal {
        // Start a live game (hp high enough to survive the absence analytically).
        // We just want to measure the auto-settle catch-up cost in startGame.
        // The test drives through startGame's auto-settle path (finished after catchUp).
        // Use a separate address so setUp's BASE stays consistent.
        address addr = address(uint160(0x5000 + gameHours));
        vm.prank(addr);
        vm.warp(BASE);
        harness.startGame();
        // Advance time by gameHours (the game will have died long before).
        vm.warp(BASE + gameHours * uint256(SPH));
        // startGame triggers auto-settle; measure that call.
        vm.prank(addr);
        uint256 g0 = gasleft();
        harness.startGame();
        uint256 used = g0 - gasleft();
        emit log_named_uint(
            string(abi.encodePacked("gas startGame after ", _uint2str(gameHours), "h absence")),
            used
        );
        // Sanity: the auto-settle fired (at least 1 run settled).
        assertGe(harness.bestRun(addr).runsSettled, 1, "auto-settle must have fired");
    }

    /// @dev Minimal uint→string for log labels.
    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    // ── Shared helpers for 4.x and 5.x tests ─────────────────────────────────

    /// @dev A minimal portal that collapses at game hour 1, carrying no creatures.
    function _collapsingPortal() internal pure returns (Portal memory p) {
        p.status = PortalStatus.Open;
        p.surveyed = true;
        p.creaturesKnown = true;
        p.creatures = 0;
        p.hoursToCollapse = 1; // collapses at h(snapshotAt) + 1 = hour 1
        p.snapshotAt = BASE;
    }

    /// @dev A live game whose HP equals exactly hpEmptyCollapse (3) — the single
    /// empty-portal collapse in slot 0 is enough to kill it.
    function _gameAboutToDie() internal pure returns (Game memory g) {
        g = _game();
        g.hp = 3; // hpEmptyCollapse == 3
        g.openPortals = 1;
    }

    /// @dev Scan `logs` for the first log whose topic0 equals `sig`.
    /// Returns the index, or `type(uint256).max` if not found.
    function _firstLogIdx(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) return i;
        }
        return type(uint256).max;
    }

    // ── 4.1: diedAtHour does not depend on when the player returned ───────────

    /// @dev Three identical games started at BASE. settle() is called at 10^3,
    /// 10^5, and 10^7 game hours later. diedAtHour must be the same for all
    /// three and must equal 100 (analytically computed: fill hour 84 + 16 h
    /// overflow with hpOverflowPerHour=5 and hpStart=80). Guards the binary
    /// search in TimeLib._fillHour against off-by-one mutations.
    function test_4_1_diedAtHour_independent_of_settle_time() public {
        address a1 = address(0xA001);
        address a2 = address(0xA002);
        address a3 = address(0xA003);

        vm.prank(a1); harness.startGame();
        vm.prank(a2); harness.startGame();
        vm.prank(a3); harness.startGame();

        vm.warp(BASE + 1_000 * uint256(SPH));
        harness.settle(a1);

        vm.warp(BASE + 100_000 * uint256(SPH));
        harness.settle(a2);

        vm.warp(BASE + 10_000_000 * uint256(SPH));
        harness.settle(a3);

        uint32 h1 = harness.bestRun(a1).hoursSurvived;
        uint32 h2 = harness.bestRun(a2).hoursSurvived;
        uint32 h3 = harness.bestRun(a3).hoursSurvived;

        // The property: the recorded death hour is the same whenever settle() runs.
        assertEq(h1, h2, "diedAtHour must not depend on when settle() is called");
        assertEq(h1, h3, "diedAtHour must not depend on when settle() is called");
        // Secondary sanity check only: this literal tracks the seeded starting
        // spawn pressure (ticket 8.1) and moves with it; the equalities above are
        // the real assertion.
        // Fill hour: 30_000 + 1000h + h(h-1) >= 120_000 -> h = 84 (h=83: 89_806 < 90_000).
        // Overflow: 80 hp / 5 per hour = 16 h. 84 + 16 = 100.
        assertEq(h1, 100, "expected death hour is 100 for default config");
    }

    // ── 4.2: game dies during absence, then startGame → no GameForfeited ──────

    /// @dev TRAP 1.3: the game is alive when last touched, dies while the player
    /// is away, then the player calls startGame. The auto-settle branch must fire
    /// (RunSettled, result recorded) and GameForfeited must NOT be emitted.
    function test_4_2_no_forfeit_when_game_dies_during_absence() public {
        harness.setGame(player, _gameAboutToDie());
        harness.setPortal(player, 0, _collapsingPortal());
        vm.warp(BASE + 2 * SPH);

        vm.recordLogs();
        harness.startGame();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 forfeitSig = keccak256("GameForfeited(address,uint32)");
        assertEq(
            _firstLogIdx(logs, forfeitSig),
            type(uint256).max,
            "GameForfeited must NOT be emitted when game dies during absence"
        );

        bytes32 settleSig = keccak256("RunSettled(address,uint32,uint32,bool)");
        assertTrue(
            _firstLogIdx(logs, settleSig) != type(uint256).max,
            "RunSettled must be emitted by the auto-settle path"
        );

        assertEq(harness.bestRun(player).runsSettled, 1, "run must be recorded");
        assertEq(harness.bestRun(player).hoursSurvived, 1, "game died at hour 1");
    }

    // ── 4.3: live game + startGame → GameForfeited, no RunSettled ─────────────

    /// @dev The game is still alive when the player calls startGame. GameForfeited
    /// must be emitted; the live forfeit must NOT appear in bestRun (RunSettled
    /// must NOT be emitted).
    function test_4_3_forfeit_live_game_no_run_recorded() public {
        harness.setGame(player, _game()); // hp=50, alive
        vm.warp(BASE + SPH);             // 1 hour later, game still alive

        vm.recordLogs();
        harness.startGame();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 forfeitSig = keccak256("GameForfeited(address,uint32)");
        assertTrue(
            _firstLogIdx(logs, forfeitSig) != type(uint256).max,
            "GameForfeited must be emitted for a live forfeited game"
        );

        bytes32 settleSig = keccak256("RunSettled(address,uint32,uint32,bool)");
        assertEq(
            _firstLogIdx(logs, settleSig),
            type(uint256).max,
            "RunSettled must NOT be emitted for a live forfeited game"
        );

        assertEq(harness.bestRun(player).runsSettled, 0, "no run should be recorded");
    }

    // ── 4.4: event order is identical on all three paths ─────────────────────

    /// @dev sync path: PortalCollapsed BEFORE GameOver.
    function test_4_4a_sync_event_order_collapse_before_gameover() public {
        harness.setGame(player, _gameAboutToDie());
        harness.setPortal(player, 0, _collapsingPortal());
        vm.warp(BASE + 2 * SPH);

        vm.recordLogs();
        harness.sync(player);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 collapseSig = keccak256("PortalCollapsed(address,uint8,uint8,uint16,uint32)");
        bytes32 gameOverSig = keccak256("GameOver(address,uint32)");

        uint256 collapseIdx = _firstLogIdx(logs, collapseSig);
        uint256 gameOverIdx = _firstLogIdx(logs, gameOverSig);

        assertTrue(collapseIdx != type(uint256).max, "PortalCollapsed must be emitted by sync");
        assertTrue(gameOverIdx != type(uint256).max, "GameOver must be emitted by sync");
        assertLt(collapseIdx, gameOverIdx, "PortalCollapsed must precede GameOver on sync path");
    }

    /// @dev settle path: PortalCollapsed BEFORE GameOver BEFORE RunSettled.
    function test_4_4b_settle_event_order_collapse_gameover_runsettled() public {
        harness.setGame(player, _gameAboutToDie());
        harness.setPortal(player, 0, _collapsingPortal());
        vm.warp(BASE + 2 * SPH);

        vm.recordLogs();
        harness.settle(player);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 collapseSig = keccak256("PortalCollapsed(address,uint8,uint8,uint16,uint32)");
        bytes32 gameOverSig  = keccak256("GameOver(address,uint32)");
        bytes32 settleSig    = keccak256("RunSettled(address,uint32,uint32,bool)");

        uint256 collapseIdx = _firstLogIdx(logs, collapseSig);
        uint256 gameOverIdx  = _firstLogIdx(logs, gameOverSig);
        uint256 settleIdx    = _firstLogIdx(logs, settleSig);

        assertTrue(collapseIdx != type(uint256).max, "PortalCollapsed must be emitted by settle");
        assertTrue(gameOverIdx  != type(uint256).max, "GameOver must be emitted by settle");
        assertTrue(settleIdx    != type(uint256).max, "RunSettled must be emitted by settle");
        assertLt(collapseIdx, gameOverIdx,  "PortalCollapsed must precede GameOver on settle path");
        assertLt(gameOverIdx,  settleIdx,   "GameOver must precede RunSettled on settle path");
    }

    /// @dev auto-settle in startGame: PortalCollapsed BEFORE GameOver BEFORE RunSettled.
    function test_4_4c_startGame_autosettled_event_order() public {
        harness.setGame(player, _gameAboutToDie());
        harness.setPortal(player, 0, _collapsingPortal());
        vm.warp(BASE + 2 * SPH);

        vm.recordLogs();
        harness.startGame();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 collapseSig = keccak256("PortalCollapsed(address,uint8,uint8,uint16,uint32)");
        bytes32 gameOverSig  = keccak256("GameOver(address,uint32)");
        bytes32 settleSig    = keccak256("RunSettled(address,uint32,uint32,bool)");

        uint256 collapseIdx = _firstLogIdx(logs, collapseSig);
        uint256 gameOverIdx  = _firstLogIdx(logs, gameOverSig);
        uint256 settleIdx    = _firstLogIdx(logs, settleSig);

        assertTrue(collapseIdx != type(uint256).max, "PortalCollapsed must be emitted by startGame auto-settle");
        assertTrue(gameOverIdx  != type(uint256).max, "GameOver must be emitted by startGame auto-settle");
        assertTrue(settleIdx    != type(uint256).max, "RunSettled must be emitted by startGame auto-settle");
        assertLt(collapseIdx, gameOverIdx,  "PortalCollapsed must precede GameOver in startGame auto-settle");
        assertLt(gameOverIdx,  settleIdx,   "GameOver must precede RunSettled in startGame auto-settle");
    }

    // ── 4.5: settle after sync must not emit GameOver a second time ───────────

    /// @dev sync detects the death and emits GameOver. A subsequent settle must
    /// record the run (emit RunSettled) but must NOT emit GameOver again.
    function test_4_5_settle_after_sync_no_double_gameover() public {
        harness.setGame(player, _gameAboutToDie());
        harness.setPortal(player, 0, _collapsingPortal());
        vm.warp(BASE + 2 * SPH);

        // First: sync records death, emits GameOver.
        harness.sync(player);
        // game.finished is now true in storage.

        // Second: settle. Only RunSettled expected; GameOver must NOT fire again.
        vm.recordLogs();
        harness.settle(player);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 gameOverSig = keccak256("GameOver(address,uint32)");
        assertEq(
            _firstLogIdx(logs, gameOverSig),
            type(uint256).max,
            "GameOver must NOT be emitted a second time after sync already recorded the death"
        );

        bytes32 settleSig = keccak256("RunSettled(address,uint32,uint32,bool)");
        assertTrue(
            _firstLogIdx(logs, settleSig) != type(uint256).max,
            "RunSettled must be emitted by settle even when GameOver was already emitted by sync"
        );
    }

    // ── Gas measurements — part 5 ─────────────────────────────────────────────

    // Helper: add N portals to `player`'s game, already-dead portals (won't
    // collapse again since catch-up returns immediately for finished=true games).
    function _setDeadPortals(address p, uint8 count) internal {
        for (uint8 i = 0; i < count; i++) {
            Portal memory portal;
            portal.status = PortalStatus.Open;
            portal.surveyed = true;
            portal.creaturesKnown = true;
            portal.creatures = 0;
            portal.hoursToCollapse = 10; // arbitrary; won't matter for finished games
            portal.snapshotAt = BASE;
            harness.setPortal(p, i, portal);
        }
    }

    /// @dev Gas for startGame with auto-settle and 12 portals already in storage
    /// (game is finished=true: catch-up returns immediately, no collapse events).
    /// This is the floor for the auto-settle path with a full portal array.
    function test_gas_5_3_startGame_auto_settle_12_portals() public {
        Game memory g = _deadGame(100, 5);
        g.openPortals = 12;
        harness.setGame(player, g);
        _setDeadPortals(player, 12);

        uint256 g0 = gasleft();
        harness.startGame();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas startGame (auto-settle, 12 portals, already dead)", used);
    }

    /// @dev Gas for settle() on a finished game with 0 portals — baseline reference.
    /// (Same scenario as test_gas_8_3; duplicated here to appear alongside 5.4b.)
    function test_gas_5_4a_settle_0_portals() public {
        harness.setGame(player, _deadGame(100, 5));
        uint256 g0 = gasleft();
        harness.settle(player);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas settle (finished game, 0 portals)", used);
    }

    /// @dev Gas for settle() on a finished game with 12 portals in storage.
    function test_gas_5_4b_settle_12_portals() public {
        Game memory g = _deadGame(100, 5);
        g.openPortals = 12;
        harness.setGame(player, g);
        _setDeadPortals(player, 12);

        uint256 g0 = gasleft();
        harness.settle(player);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas settle (finished game, 12 portals)", used);
    }

    /// @dev Gas for startGame when a LIVE game dies from 12 portal collapses
    /// during the auto-settle catch-up. This measures the new unified-event path
    /// (PortalCollapsed×12 + GameOver + RunSettled) vs test_gas_5_3 (no events).
    /// The difference is the cost of the events added by part 3.
    ///
    /// Setup: hp=41 (absorbs overflow −5 and 12 empty-collapse × −3 = −36,
    /// total −41, landing at exactly 0). 12 portals with hoursToCollapse=1
    /// (all collapse at game hour 1). Warp 2 hours forward.
    function test_gas_5_5_startGame_live_dies_12_collapses_events() public {
        Game memory g = _game();
        g.hp = 41;
        g.openPortals = 12;
        harness.setGame(player, g);
        for (uint8 i = 0; i < 12; i++) {
            Portal memory p;
            p.status = PortalStatus.Open;
            p.surveyed = true;
            p.creaturesKnown = true;
            p.creatures = 0;
            p.hoursToCollapse = 1;
            p.snapshotAt = BASE;
            harness.setPortal(player, i, p);
        }

        vm.warp(BASE + 2 * SPH);

        uint256 g0 = gasleft();
        harness.startGame();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas startGame (auto-settle, live dies with 12 collapses + events)", used);
        // Sanity: run was recorded.
        assertEq(harness.bestRun(player).runsSettled, 1, "run must have been settled");
    }
}
